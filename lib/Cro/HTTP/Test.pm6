unit module Cro::HTTP::Test;
use Cro::HTTP::Client;
use Cro::HTTP::Test::ChannelServer;
use Cro::MediaType;
use Cro::Transform;
use Cro::Uri;
use Test;
use Test::Assertion;

my class X::Cro::HTTP::Test::OnlyOneBody is Exception {
    method message() {
        "Can only use one of `body`, `body-blob`, `body-text`, or `json`"
    }
}
my class X::Cro::HTTP::Test::BadHeaderTest is Exception {
    has $.got;
    method message() {
        "Header tests should be a Pair or an Iterable of Pair, but got '$!got.perl()'"
    }
}
my class X::Cro::HTTP::Test::BadFakeAuth is Exception {
    method message() {
        "Can only use `fake-auth` when testing a Cro transform, not a URI"
    }
}

my class TestContext {
    has Cro::HTTP::Client $.client is required;
    has Str $.base-path = '';
    has %.client-options;

    method derive($add-base, %add-options) {
        my $new-base = merge-path($!base-path, $add-base);
        my %new-options := merge-options(%!client-options, %add-options);
        return TestContext.new(:$!client, :base-path($new-base), :client-options(%new-options));
    }
}

multi test-service(Cro::Transform $testee, &tests, :$fake-auth, :$http,
                   Str :$peer-host, Int :$peer-port, *%client-options --> Nil) is export is test-assertion {
    my $*CRO-HTTP-TEST-AUTH-HOLDER = Cro::HTTP::Test::FakeAuthHolder.new;
    with $fake-auth {
        $*CRO-HTTP-TEST-AUTH-HOLDER.push-auth($_);
    }
    my ($client, $service) = build-client-and-service($testee, %client-options,
        :fake-auth-holder($*CRO-HTTP-TEST-AUTH-HOLDER), :$http, :$peer-host, :$peer-port);
    $service.start;
    my $started = True;
    LEAVE $service.stop if $started;
    test-service-run $client, &tests;
}

multi test-service(Str $uri, &tests, :$fake-auth, *%client-options --> Nil) is export is test-assertion {
    with $fake-auth {
        die X::Cro::HTTP::Test::BadFakeAuth.new;
    }
    test-service-run Cro::HTTP::Client.new(base-uri => $uri, |%client-options), &tests;
}

sub test-service-run($client, &tests --> Nil) {
    my TestContext $*CRO-HTTP-TEST-CONTEXT .= new(:$client);
    tests();
}

multi test-given(Str $new-base, &tests, :$fake-auth, *%client-options --> Nil) is export is test-assertion {
    my TestContext $orig-context = $*CRO-HTTP-TEST-CONTEXT;
    {
        my $*CRO-HTTP-TEST-CONTEXT = $orig-context.derive($new-base, %client-options);
        run-test-given(&tests, :$fake-auth);
    }
}

multi test-given(&tests, :$fake-auth, *%client-options --> Nil) is export is test-assertion {
    my TestContext $orig-context = $*CRO-HTTP-TEST-CONTEXT;
    {
        my $*CRO-HTTP-TEST-CONTEXT = $orig-context.derive(Nil, %client-options);
        run-test-given(&tests, :$fake-auth);
    }
}

sub run-test-given(&tests, :$fake-auth --> Nil) {
    with $fake-auth {
        with $*CRO-HTTP-TEST-AUTH-HOLDER -> $holder {
            $holder.push-auth($fake-auth);
            tests();
            LEAVE $holder.pop-auth();
        }
    }
    else {
        tests();
    }
}

class TestRequest {
    has Str $.method is required;
    has Str $.path = '';
    has %.client-options;
    submethod TWEAK() {
        with %!client-options<json> -> $json {
            %!client-options<content-type> ||= 'application/json';
            %!client-options<body> = $json;
            %!client-options<json>:delete;
        }
    }
}

multi request(Str $method, Str $path, *%client-options --> TestRequest) is export is test-assertion {
    TestRequest.new(:$method, :$path, :%client-options)
}
multi request(Str $method, *%client-options --> TestRequest) is export is test-assertion {
    TestRequest.new(:$method, :%client-options)
}

multi get(Str $path, *%client-options --> TestRequest) is export is test-assertion {
    request('GET', $path, |%client-options)
}
multi get(*%client-options --> TestRequest) is export is test-assertion {
    request('GET', |%client-options)
}

multi post(Str $path, *%client-options --> TestRequest) is export is test-assertion {
    request('POST', $path, |%client-options)
}
multi post(*%client-options --> TestRequest) is export is test-assertion {
    request('POST', |%client-options)
}

proto put(|) is export { * }
multi put(Str $path, *%client-options --> TestRequest) is test-assertion {
    request('PUT', $path, |%client-options)
}
multi put(*%client-options --> TestRequest) is test-assertion {
    request('PUT', |%client-options)
}

multi delete(Str $path, *%client-options --> TestRequest) is export is test-assertion {
    request('DELETE', $path, |%client-options)
}
multi delete(*%client-options --> TestRequest) is export is test-assertion {
    request('DELETE', |%client-options)
}

multi patch(Str $path, *%client-options --> TestRequest) is export is test-assertion {
    request('PATCH', $path, |%client-options)
}
multi patch(*%client-options --> TestRequest) is export is test-assertion {
    request('PATCH', |%client-options)
}

multi head(Str $path, *%client-options --> TestRequest) is export is test-assertion {
    request('HEAD', $path, |%client-options)
}
multi head(*%client-options --> TestRequest) is export is test-assertion {
    request('HEAD', |%client-options)
}

sub test(TestRequest:D $request, :$status, :$content-type, :header(:$headers),
         :$body-text, :$body-blob, :$body, :$json --> Nil) is export is test-assertion {
    with $*CRO-HTTP-TEST-CONTEXT -> $ctx {
        my $method = $request.method;
        my $path = merge-path($ctx.base-path, $request.path);

        my $resp;
        subtest "$method $path" => {
            my %options := merge-options($ctx.client-options, $request.client-options);
            $resp = get-response($ctx.client, $method, $path, %options);
            with $status {
                when Int {
                    is $resp.status, $status, 'Status is acceptable';
                }
                default {
                    ok $resp.status ~~ $status, 'Status is acceptable';
                }
            }
            with $content-type {
                when Cro::MediaType {
                    test-media-type($resp.content-type, $_);
                }
                when Str {
                    test-media-type($resp.content-type, Cro::MediaType.parse($_));
                }
                default {
                    ok $resp.content-type ~~ $content-type, 'Content type is acceptable';
                }
            }
            with $headers {
                for .list {
                    when Pair {
                        my $header-name = .key;
                        my $got-value = $resp.header($header-name);
                        given .value {
                            when Str {
                                is $got-value, $_, "$header-name header";
                            }
                            default {
                                ok $got-value ~~ $_, "$header-name header";
                            }
                        }
                    }
                    default {
                        die X::Cro::HTTP::Test::BadHeaderTest.new(got => $_);
                    }
                }
            }
            with $json {
                if $body.defined || $body-text.defined || $body-blob.defined {
                    die X::Cro::HTTP::Test::OnlyOneBody;
                }
                without $content-type {
                    given $resp.content-type {
                        ok .type eq 'application' && .subtype-name eq 'json' || .suffix eq 'json',
                            'Content type is recognized as a JSON one';
                    }
                }
                if $json ~~ Code {
                    ok await($resp.body) ~~ $json, 'Body is acceptable';
                }
                else {
                    is-deeply await($resp.body), $json, 'Body is acceptable';
                }
            }
            orwith $body {
                if $body-text.defined || $body-blob.defined {
                    die X::Cro::HTTP::Test::OnlyOneBody;
                }
                ok await($resp.body) ~~ $body, 'Body is acceptable';
            }
            orwith $body-text {
                if $body-blob.defined {
                    die X::Cro::HTTP::Test::OnlyOneBody;
                }
                ok await($resp.body-text) ~~ $body-text, 'Body is acceptable';
            }
            orwith $body-blob {
                ok await($resp.body-blob) ~~ $body-blob, 'Body is acceptable';
            }
        };

        return $resp;
    }
    else {
        die "Should use `test` within a `test-service` block";
    }
}

sub merge-path($base, $rel) {
    return $base unless $rel;
    return $rel unless $base;
    return Cro::Uri.parse-ref($base).add($rel).Str;
}

sub merge-options(%base, %new) {
    return %base unless %new;
    return %new unless %base;
    my %result = %base;
    for %new.kv -> $_, $value {
        when 'cookies' {
            my @result = @(%base<cookies> // ());
            append @result, @(%new<cookies> // ());
            %result<cookies> = @result;
        }
        when 'headers' {
            my @result = @(%base<headers> // ());
            append @result, @(%new<headers> // ());
            %result<headers> = @result;
        }
        default {
            %result{$_} = $value;
        }
    }
    return %result;
}

sub get-response($client, $method, $path, %options) {
    return await $client.request($method, $path, %options);
    CATCH {
        when X::Cro::HTTP::Error {
            return .response;
        }
    }
}

sub test-media-type(Cro::MediaType $got, Cro::MediaType $expected) is test-assertion {
    if $expected.parameters -> @params {
        subtest 'Content type is acceptable' => {
            is $got.type-and-subtype, $expected.type-and-subtype, 'Media type and subtype are correct';
            for @params {
                ok any($got.parameters) eq $_, "Have parameter $_";
            }
        }
    }
    else {
        is $got.type-and-subtype, $expected.type-and-subtype, 'Content type is acceptable';
    }
}

sub is-ok(|c) is hidden-from-backtrace is export is test-assertion {
    test |c, status => 200
}
sub is-no-content(|c) is hidden-from-backtrace is export is test-assertion {
    test |c, status => 204
}
sub is-bad-request(|c) is hidden-from-backtrace is export is test-assertion {
    test |c, status => 400
}
sub is-unauthorized(|c) is hidden-from-backtrace is export is test-assertion {
    test |c, status => 401
}
sub is-forbidden(|c) is hidden-from-backtrace is export is test-assertion {
    test |c, status => 403
}
sub is-not-found(|c) is hidden-from-backtrace is export is test-assertion {
    test |c, status => 404
}
sub is-method-not-allowed(|c) is hidden-from-backtrace is export is test-assertion {
    test |c, status => 405
}
sub is-conflict(|c) is hidden-from-backtrace is export is test-assertion {
    test |c, status => 409
}
sub is-unprocessable-entity(|c) is hidden-from-backtrace is export is test-assertion {
    test |c, status => 422
}

# Re-export plan and done-testing from Test, and use it ourselves for doing the
# test assertions.
EXPORT::DEFAULT::<&plan> := &plan;
EXPORT::DEFAULT::<&done-testing> := &done-testing;
