use strict;
use warnings;

use Test::More;

use Dancer2::Core::Session;
use Dancer2::Session::DBIC;
use Plack::Test;
use HTTP::Request::Common;

use File::Spec;
use lib File::Spec->catdir( 't', 'lib' );

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
			{DBIC => $options}};

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
    }

    my $app =  Dancer2->runner->psgi_app;

    is( ref $app, 'CODE', 'Got app' );

    test_psgi $app, sub {
      my $cb = shift;

      like(
        $cb->( GET '/id' )->content,
        qr/^[0-9a-z_-]+$/i,
        'Retrieve session id',
      );

      is(
        $cb->( GET '/getfoo' )->content,
        '',
        'Retrieve pristine foo key',
      );

      is(
	$cb->( GET '/putfoo' )->content,
	'bar',
	'Set foo key to bar',
	);

    };
}

done_testing;
