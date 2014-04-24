package Dancer2::Session::DBIC;

use Moo;
use Dancer2::Core::Types;
use JSON;

our $VERSION = '0.003';

=head1 NAME

Dancer2::Session::DBIC - DBIx::Class session engine for Dancer2

=head1 VERSION

0.003

=head1 DESCRIPTION

This module implements a session engine for Dancer2 by serializing the session,
and storing it in a database via L<DBIx::Class>. The default serialization method is L<JSON>,
though one can specify any serialization format you want. L<YAML> and L<Storable> are
viable alternatives.

JSON was chosen as the default serialization format, as it is fast, terse, and portable.

=head1 SYNOPSIS

Example configuration:

    session: "DBIC"
    engines:
      session:
        DBIC:
          dsn:      "DBI:mysql:database=testing;host=127.0.0.1;port=3306" # DBI Data Source Name
          schema_class:    "Interchange6::Schema"  # DBIx::Class schema
          user:     "user"      # Username used to connect to the database
          password: "password"  # Password to connect to the database
          resultset: "MySession" # DBIx::Class resultset, defaults to Session
          id_column: "my_session_id" # defaults to sessions_id
          data_column: "my_session_data" # defaults to session_data

=head1 SESSION EXPIRATION

A timestamp field that updates when a session is updated is recommended, so you can expire sessions server-side as well as client-side.

This session engine will not automagically remove expired sessions on the server, but with a timestamp field as above, you should be able to to do this manually.

=cut

use strict;

# use Dancer2;
use DBIx::Class;
use Try::Tiny;
use Scalar::Util qw(blessed);

with 'Dancer2::Core::Role::SessionFactory';

my %dbic_handles;

=head1 ATTRIBUTES

=head2 schema_class

DBIx::Class schema class, e.g. L<Interchange6::Schema>.

=cut

has schema_class => (
    is => 'ro',
);

=head2 resultset

DBIx::Class resultset, defaults to C<Session>.

=cut

has resultset => (
    is => 'ro',
    default => 'Session',
);

=head2 id_column

Column for session id, defaults to C<sessions_id>.

=cut

has id_column => (
    is => 'ro',
    default => 'sessions_id',
);

=head2 data_column

Column for session data, defaults to C<session_data>.

=cut

has data_column => (
    is => 'ro',
    default => 'session_data',
);

=head2 dsn

L<DBI> dsn to connect to the database.

=cut

has dsn => (
    is => 'ro',
);

=head2 user

Database username.

=cut

has user => (
    is => 'ro',
);

=head2 password

Database password.

=cut

has password => (
    is => 'ro',
);

=head2 schema

L<DBIx::Class> schema.

=cut

has schema => (
    is => 'ro',
);

=head1 METHODS

=cut

sub _sessions { return [] };

=head2 _flush

Write the session to the database. Returns the session object.

=cut

sub _flush {
    my ($self, $id, $session) = @_;
    my $handle = $self->_dbic;

    my %session_data = ($handle->{id_column} => $id,
                        $handle->{data_column} => $self->_serialize($session),
                       );

    $self->_rset->update_or_create(\%session_data);

    return $self;
}

=head2 _retrieve($id)

Look for a session with the given id.

Returns the session object if found, C<undef> if not.
Dies if the session was found, but could not be deserialized.

=cut

sub _retrieve {
    my ($self, $session_id) = @_;
    my $session_object;

    $session_object = $self->_rset->find($session_id);

    # Bail early if we know we have no session data at all
    if (!defined $session_object) {
        die "Could not retrieve session ID: $session_id";
        return;
    }

    my $session_data = $session_object->session_data;

    # No way to check that it's valid JSON other than trying to deserialize it
    my $session = try {
        $self->_deserialize($session_data);
    } catch {
        die "Could not deserialize session ID: $session_id - $_";
        return;
    };

    return $session;
}


=head2 _destroy()

Remove the current session object from the database.

=cut

sub _destroy {
    my $self = shift;

    if (!defined $self->id) {
        die "No session ID passed to destroy method";
        return;
    }

    $self->_rset->find($self->id)->delete;
}

# Creates and connects schema

sub _dbic {
    my $self = shift;

    # To be fork safe and thread safe, use a combination of the PID and TID (if
    # running with use threads) to make sure no two processes/threads share
    # handles.  Implementation based on DBIx::Connector by David E. Wheeler.
    my $pid_tid = $$;
    $pid_tid .= '_' . threads->tid if $INC{'threads.pm'};

    # OK, see if we have a matching handle
    my $handle = $dbic_handles{$pid_tid};

    if ($handle->{schema}) {
        return $handle;
    }

    # Prefer an active schema over a schema class.
    my $schema = $self->schema;

    if (defined $schema) {
        if (blessed $schema) {
            $handle->{schema} = $schema;
        }
        else {
            $handle->{schema} = $schema->();
        }
    }
    elsif (! defined $self->schema_class) {
        die "No schema class defined.";
    }
    else {
        my $schema_class = $self->schema_class;

	my $settings = {};
 
        $handle->{schema} = $self->_load_schema_class($schema_class,
                                                      $self->dsn,
                                                      $self->user,
                                                      $self->password);
    }

    $handle->{resultset} = $self->resultset;
    $handle->{id_column} = $self->id_column;
    $handle->{data_column} = $self->data_column;

    $dbic_handles{$pid_tid} = $handle;

    return $handle;
}

# Returns specific resultset
sub _rset {
    my ($self, $name) = @_;

    my $handle = $self->_dbic;

    return $handle->{schema}->resultset($handle->{resultset});
}

# Loads schema class
sub _load_schema_class {
    my ($self, $schema_class, @conn_info) = @_;
    my ($schema_object);

    if ($schema_class) {
        $schema_class =~ s/-/::/g;
        eval { load $schema_class };
        die "Could not load schema_class $schema_class: $@" if $@;
        $schema_object = $schema_class->connect(@conn_info);
    } else {
        my $dbic_loader = 'DBIx::Class::Schema::Loader';
        eval { load $dbic_loader };
        die "You must provide a schema_class option or install $dbic_loader."
            if $@;
        $dbic_loader->naming('v7');
        $schema_object = DBIx::Class::Schema::Loader->connect(@conn_info);
    }

    return $schema_object;
}

# Default Serialize method
sub _serialize {
    my $self = shift;
    my $session = shift;

#    my $settings = setting('session_options');

#    if (defined $settings->{serializer}) {
#        return $settings->{serializer}->({%$self});
#    }

    # A session is by definition ephemeral - Store it compactly
    # This is the Dancer2 function, not from JSON.pm
    my $json = JSON->new->allow_blessed->convert_blessed;
    return $json->encode($session);
}


# Default Deserialize method
sub _deserialize {
    my ($self, $json) = @_;
#    my $settings = setting('session_options');

#    if (defined $settings->{deserializer}) {
#        return $settings->{deserializer}->($json);
#    }

    # This is the Dancer2 function, not from JSON.pm
    my $json_obj = JSON->new->allow_blessed->convert_blessed;
    return $json_obj->decode($json);
}

=head1 SEE ALSO

L<Dancer2>, L<Dancer2::Session>

=head1 AUTHOR

Stefan Hornburg (Racke) <racke@linuxia.de>

=head1 ACKNOWLEDGEMENTS

Based on code from L<Dance::Session::DBI> written by James Aitken
and code from L<Dance::Plugin::DBIC> written by Naveed Massjouni.

=head1 COPYRIGHT AND LICENSE

This software is copyright (c) Stefan Hornburg.

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.

=cut


1;
