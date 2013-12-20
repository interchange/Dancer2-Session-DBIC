use strict;
use warnings;

use Test::More tests => 8;

use Dancer::Session::DBIC;
use Dancer qw(:syntax :tests);

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

    set session => 'DBIC';
    set session_options => {
                            %{$schema_options || {}},
                            schema => sub {return $schema},
                           };

    my $session = session->create;

    isa_ok($session, 'Dancer::Session::DBIC');

    my $session_id = session->id;

    ok(defined($session_id) && $session_id > 0, 'Testing session id')
        || diag "Session id: ", $session_id;

    session foo => 'bar';

    my $session_value = session('foo');

    ok($session_value eq 'bar', 'Testing session value')
        || diag "Session value: ", $session_value;

    # destroy session
    session->destroy;

    my $next_session_id = session->id;

    my $resultset = $schema_options->{resultset} || 'Session';
    my $ret = $schema->resultset($resultset)->find($session_id);

    ok(! defined($ret), 'Testing session destruction')
        || diag "Return value: ", $ret;
}
