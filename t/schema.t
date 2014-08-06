use strict;
use warnings;

use Test::More;

use Dancer2::Core::Session;
use Dancer2::Session::DBIC;
use Plack::Test;
use HTTP::Request::Common;

use File::Spec;
use lib File::Spec->catdir( 't', 'lib' );

use Data::Dumper;
use DBICx::TestDatabase;

test_session_schema('Test::Schema');
test_session_schema('Test::Custom', {resultset => 'Custom',
                                     id_column => 'customs_id',
                                     data_column => 'custom_data'});

sub test_session_schema {
    my ($schema_class, $schema_options) = @_;
    my $schema = DBICx::TestDatabase->new($schema_class);

    # create object
    my $dbic_session = Dancer2::Session::DBIC->new(schema => $schema);

    isa_ok($dbic_session, 'Dancer2::Session::DBIC');

    isa_ok($dbic_session->schema, $schema_class);

    {
        package Foo;

        use Dancer2;

        my $options = {%{$schema_options || {}},
                       schema => sub {return $schema},
                   };

        # engines needs to set before the session itself
        set engines => {session =>
                            {
                                DBIC => $options}};

        set session => 'DBIC';

        get '/id' => sub {
            return session->id;
        };

        get '/getfoo' => sub {
            return session('foo');
        };

        get '/putfoo' => sub {
            session foo => 'bar';
            return session('foo');
        };

        get '/destroy' => sub {
            if (app->can('destroy_session')) {
                app->destroy_session;
            }
            # legacy
            else {
                context->destroy_session;
            }
            return "Session destroyed";
        };

        get '/sessionid' => sub {
            return session->id;
        };

    }

    my $app =  Dancer2->runner->psgi_app;

    is( ref $app, 'CODE', 'Got app' );

    test_psgi $app, sub {
        my $cb = shift;

        my $res = $cb->( GET '/sessionid' );

        my $newid = $res->content;
        # extract the cookie
        my $cookie = $res->header('Set-Cookie');
        $cookie =~ s/^(.*?);.*$/$1/s;
        ok ($cookie, "Got the cookie: $cookie");
        my @headers = (Cookie => $cookie);

        like(
            $cb->( GET '/id', @headers)->content,
            qr/^[0-9a-z_-]+$/i,
            'Retrieve session id',
        );

        is(
            $cb->( GET '/getfoo', @headers )->content,
            '',
            'Retrieve pristine foo key',
        );

        is(
            $cb->( GET '/putfoo', @headers )->content,
            'bar',
            'Set foo key to bar',
        );

        is(
            $cb->( GET '/getfoo', @headers )->content,
            'bar',
            'Retrieve foo key which is "bar" now',
        );

        like(
             $cb->( GET '/sessionid', @headers )->content,
             qr/\w/,
             "Found session id",
        );
        my $oldid = $cb->( GET '/sessionid', @headers )->content;
        is($oldid, $newid, "Same id, session holds");

        is(
           $cb->( GET '/destroy', @headers)->content,
           'Session destroyed',
           'Session destroyed without crashing',
          );

        is(
            $cb->( GET '/getfoo', @headers )->content,
            '',
            'Retrieve pristine foo key after destroying',
        );

        $newid = $cb->( GET '/sessionid', @headers )->content;

        ok($newid ne $oldid, "New and old ids differ");
    };
}

done_testing;
