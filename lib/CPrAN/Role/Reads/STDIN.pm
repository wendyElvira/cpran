package CPrAN::Role::Reads::STDIN;

use Moose::Role;

requires 'execute';

around execute => sub {
  my $orig = shift;
  my $self = shift;

  my ($opt, $args) = @_;

  if (scalar @{$args} eq 1 and $args->[0] eq '-') {
    $self->app->yes(1) if $self->app->can('yes');
    while (<STDIN>) {
      chomp;
      push @{$args}, $_;
    }
    shift @{$args};
  }

  return $self->$orig($opt, $args);
};

1;
