package Mojo::IOLoop::Stream::HTTPClient;
use Mojo::Base 'Mojo::IOLoop::Stream';

use Mojo::Util qw(term_escape);
use Mojo::UserAgent::Transactor;
use Scalar::Util 'weaken';

use constant DEBUG => $ENV{MOJO_USERAGENT_DEBUG} || 0;

has request_timeout => sub { $ENV{MOJO_REQUEST_TIMEOUT} // 0 };
has transactor      => sub { Mojo::UserAgent::Transactor->new };

sub new {
  my $self = shift->SUPER::new(@_);
  $self->on(read => sub { shift->_read_content(shift) });
  $self->on(close => sub { $_[0]->{closing}++ || $_[0]->_finish(1) });
  return $self;
}

sub process {
  my ($self, $tx) = @_;

  return undef if $self->{tx};
  $self->{tx} = $tx;

  my $handle = $self->handle;
  unless ($handle->isa('IO::Socket::UNIX')) {
    $tx->local_address($handle->sockhost)->local_port($handle->sockport);
    $tx->remote_address($handle->peerhost)->remote_port($handle->peerport);
  }

  weaken $self;
  $tx->on(resume => sub { $self->_write_content });
  if (my $timeout = $self->request_timeout) {
    $self->{req_timeout} = $self->reactor->timer(
      $timeout => sub { $self->_error('Request timeout') });
  }
  $self->_write_content;
}

sub _error {
  my ($self, $err) = @_;
  $self->{tx}->res->error({message => $err}) if $self->{tx};
  $self->_finish(1);
}

sub _finish {
  my ($self, $close) = @_;

  # Remove request timeout and finish transaction
  $self->reactor->remove($self->{req_timeout}) if $self->{req_timeout};
  return ++$self->{closing} && $self->close unless my $old = delete $self->{tx};

  # Premature connection close
  my $res = $old->closed->res->finish;
  if ($close && !$res->code && !$res->error) {
    $res->error({message => 'Premature connection close'});
  }

  # Always remove connection for WebSockets
  return ++$self->{closing} && $self->close_gracefully if $old->is_websocket;

  # Upgrade connection to WebSocket
  if (my $new = $self->transactor->upgrade($old)) {
    weaken $self;
    $new->on(resume => sub { $self->_write_content });
    $self->emit(upgrade => ($self->{tx} = $new));
    return $new->client_read($old->res->content->leftovers);
  }

  ++$self->{closing} && $self->close_gracefully
    if $old->error || !$old->keep_alive;
  $res->error({message => $res->message, code => $res->code}) if $res->is_error;
  $self->emit(finish => $old);
}

sub _read_content {
  my ($self, $chunk) = @_;

  # Corrupted connection
  return $self->close unless my $tx = $self->{tx};

  warn term_escape "-- Client <<< Server (@{[_url($tx)]})\n$chunk\n" if DEBUG;
  $tx->client_read($chunk);
  $self->_finish if $tx->is_finished;
}

sub _url { shift->req->url->to_abs }

sub _write_content {
  my $self = shift;

  # Protect from resume event recursion
  return if !(my $tx = $self->{tx}) || $self->{cont_writing};
  local $self->{cont_writing} = 1;
  my $chunk = $tx->client_write;
  warn term_escape "-- Client >>> Server (@{[_url($tx)]})\n$chunk\n" if DEBUG;
  return unless length $chunk;
  weaken $self;
  $self->write($chunk => sub { $self->_write_content });
}

1;

=encoding utf8

=head1 NAME

Mojo::IOLoop::Stream::HTTPClient - Non-blocking I/O HTTP client stream

=head1 SYNOPSIS

  use Mojo::IOLoop::Client;
  use Mojo::IOLoop::Stream::HTTPClient;
  use Mojo::UserAgent::Transactor;
  
  # Create transaction
  my $tx = Mojo::UserAgent::Transactor->new->tx(GET => 'http://mojolicious.org');
  
  # Create socket connection
  my $client = Mojo::IOLoop::Client->new;
  $client->on(
    connect => sub {
      my $stream = Mojo::IOLoop::Stream::HTTPClient->new(pop);
  
      $stream->on(finish => sub {
          my ($stream, $tx) = @_;
          say $tx->res->code;
        }
      );
      $stream->start;
      $stream->process($tx);
    }
  
  );
  
  $client->connect(address => 'mojolicious.org', port => 80);
  $client->reactor->start;

=head1 DESCRIPTION

Adds HTTP and WebSocket requests processing to L<Mojo::IOLoop::Stream>
containers. With automatic WebSocket upgrades.

=head1 EVENTS

L<Mojo::IOLoop::Stream::HTTPClient> inherits all events from
L<Mojo::IOLoop::Stream> and can emit the following new ones.

=head2 finish

  $stream->on(finish => sub {
    my ($stream, $tx) = @_;
    ...
  });

Emitted when transaction is finished.

=head1 ATTRIBUTES

L<Mojo::IOLoop::Stream::HTTPClient> inherits all attributes from
L<Mojo::IOLoop::Stream> and implements the following ones.

=head2 request_timeout

  my $timeout = $stream->request_timeout;
  $stream     = $stream->request_timeout(5);

Maximum amount of time in seconds sending the request and receiving a whole
response may take before getting canceled, defaults to the value of the
C<MOJO_REQUEST_TIMEOUT> environment variable or C<0>. Setting the value to C<0>
will allow to wait indefinitely.

=head2 transactor

  my $t   = $stream->transactor;
  $stream = $stream->transactor(Mojo::UserAgent::Transactor->new);

Transaction builder, defaults to a L<Mojo::UserAgent::Transactor> object.

=head1 METHODS

Mojo::IOLoop::Stream::HTTPClient inherits all methods from
L<Mojo::IOLoop::Stream> and implements the following new ones.

=head2 new

  my $stream = Mojo::IOLoop::Stream::HTTPClient->new($handle);

Construct a new L<Mojo::IOLoop::Stream::HTTPClient> object.

=head2 process

  my $stream = Mojo::IOLoop::Stream::HTTPClient->new($handle);
  $stream->on(finish => sub {
      my ($stream, $tx) = @_;
      ...
    }
  );
  $stream->start;
  $stream->process($tx);

Process a transaction with current connection.

=head1 SEE ALSO

L<Mojolicious>, L<Mojolicious::Guides>, L<http://mojolicious.org>.

=cut

# vim: tabstop=2 softtabstop=2 expandtab shiftwidth=2 smarttab tw=81 fo+=t fo-=l

