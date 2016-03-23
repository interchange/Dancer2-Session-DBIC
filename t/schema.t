use strict;
use warnings;

use utf8;
use open ':std', ':encoding(utf8)';
use Test::More;

use Dancer2::Session::DBIC;
use Plack::Test;
use HTTP::Request::Common;

use File::Spec;
use lib File::Spec->catdir( 't', 'lib' );

use DBICx::TestDatabase;

test_session_schema('Test::Schema');
test_session_schema('Test::SchemaNonPK');
test_session_schema('Test::Custom', {resultset => 'Custom',
                                     id_column => 'id',
                                     data_column => 'data'});

# also test with specific serializers
foreach my $serializer ( 'JSON', 'Sereal', 'YAML' ) {

    # some underlying modules are not prereqs so check here if we can
    # require the underlying module for all serializers except JSON
    if ( $serializer eq 'Sereal' ) {
        eval "use Sereal::Encoder";
        if ( $@ ) {
            diag "Sereal::Encoder not installed";
            next;
        }
        eval "use Sereal::Decoder";
        if ( $@ ) {
            diag "Sereal::Decoder not installed";
            next;
        }
    }
    elsif ( $serializer eq 'YAML' ) {
        eval "use YAML";
        if ( $@ ) {
            diag "YAML not installed";
            next;
        }
    }

    note "setting serialzier to $serializer";
    my $dbic_session =
      test_session_schema( 'Test::Schema', { serializer => $serializer } );

    isa_ok( $dbic_session->serializer_object,
        "Dancer2::Session::DBIC::Serializer::$serializer" );
}

sub test_session_schema {
    %Dancer2::Session::DBIC::dbic_handles = ();
    my ($schema_class, $schema_options) = @_;

    note "Testing $schema_class";
    my $schema = DBICx::TestDatabase->new($schema_class);
    $schema_options ||= {};

    # create object
    my $dbic_session =
      Dancer2::Session::DBIC->new( schema => $schema, %$schema_options );

    isa_ok($dbic_session, 'Dancer2::Session::DBIC');

    isa_ok($dbic_session->schema, $schema_class);

    my $pk = $dbic_session->id_column;
    my $pk_expected = $schema_options->{id_column} || 'sessions_id';

    cmp_ok( $pk, 'eq', $pk_expected,
        "Test name of column for session ID for $schema_class" );

    my $rs = $dbic_session->resultset;
    my $rs_expected = $schema_options->{resultset} || 'Session';

    cmp_ok($rs, 'eq', $rs_expected, "Test name of resultset for $schema_class");

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

        get '/getcamel' => sub {
            return session('camel');
        };

        get '/putcamel' => sub {
            session camel => 'ラクダ';
            return session('camel');
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

        my $newid = $res->decoded_content;
        # extract the cookie
        my $cookie = $res->header('Set-Cookie');
        $cookie =~ s/^(.*?);.*$/$1/s;
        ok ($cookie, "Got the cookie: $cookie");
        my @headers = (Cookie => $cookie);

        my $session_id = $cb->( GET '/id', @headers)->decoded_content;
        like(
            $session_id,
            qr/^[0-9a-z_-]+$/i,
            'Retrieve session id',
        );

        is(
            $cb->( GET '/getfoo', @headers )->decoded_content,
            '',
            'Retrieve pristine foo key',
        );

        is(
            $cb->( GET '/putfoo', @headers )->decoded_content,
            'bar',
            'Set foo key to bar',
        );

        is(
            $cb->( GET '/getfoo', @headers )->decoded_content,
            'bar',
            'Retrieve foo key which is "bar" now',
        );

        is(
            $cb->( GET '/getcamel', @headers )->decoded_content,
            '',
            'Retrieve pristine camel key',
        );

        is(
            $cb->( GET '/putcamel', @headers )->decoded_content,
            'ラクダ',
            'Set camel key to ラクダ',
        );

        is(
            $cb->( GET '/getcamel', @headers )->decoded_content,
            'ラクダ',
            'Retrieve camel key which is "ラクダ" now',
        );

        like(
             $cb->( GET '/sessionid', @headers )->decoded_content,
             qr/\w/,
             "Found session id",
        );
        my $oldid = $cb->( GET '/sessionid', @headers )->decoded_content;
        is($oldid, $newid, "Same id, session holds");

        is(
           $cb->( GET '/destroy', @headers)->decoded_content,
           'Session destroyed',
           'Session destroyed without crashing',
          );

        is(
            $cb->( GET '/getfoo', @headers )->decoded_content,
            '',
            'Retrieve pristine foo key after destroying',
        );

        $newid = $cb->( GET '/sessionid', @headers )->decoded_content;

        ok($newid ne $oldid, "New and old ids differ");
    };

    return $dbic_session;
}

done_testing;
