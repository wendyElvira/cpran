package CPrAN::Command::upgrade;
# ABSTRACT: upgrade plugins to their latest version

use Moose;

extends qw( MooseX::App::Cmd::Command );

with 'MooseX::Getopt';
with 'CPrAN::Role::Processes::Praat';
with 'CPrAN::Role::Reads::STDIN';

require Carp;
use Try::Tiny;
use Capture::Tiny 'capture';
use File::Which;
use Lingua::EN::Inflexion;

has [qw(
  git test log force
)] => (
  is  => 'rw',
  isa => 'Bool',
  traits => [qw(Getopt)],
);

has '+git' => (
  lazy => 1,
  documentation => 'request / disable git support',
  default => 1,
);

has '+test' => (
  lazy => 1,
  default => 1,
  documentation => 'request / disable tests',
);

has '+log' => (
  lazy => 1,
  default => 1,
  documentation => 'request / disable log of tests',
);

has '+force' => (
  lazy => 1,
  default => 0,
  documentation => 'ignore failing tests',
);

=head1 NAME

=encoding utf8

B<upgrade> - Upgrades installed CPrAN plugins to their latest versions

=head1 SYNOPSIS

cpran upgrade [options] [arguments]

=head1 DESCRIPTION

Upgrades the specified CPrAN plugins to their latest known versions.

=cut

=pod

B<upgrade> can take as argument a list of plugin names. If provided, only
those plugins will be upgraded. Otherwise, all installed plugins will be checked
for updates and upgraded. This second case should be the recommended use, but it
is not currently implemented.

=cut

sub validate_args {
  my ($self, $opt, $args) = @_;

  # Git support is enabled if
  # 1. git is available
  # 2. Git::Repository is installed
  # 3. The user has not turned it off by setting --nogit
  if ($self->git) {
    try {
      $self->git( which('git') ? 1 : 0 )
        or die "Could not find path to git binary. Is git installed?\n";
      require Git::Repository;
    }
    catch {
      $self->app->logger->warn('Disabling git support');
      $self->app->logger->debug($_);
      $self->git(0);
    }
  }
}

=head1 EXAMPLES

    # Upgrades all installed plugins
    cpran upgrade
    # Upgrade specific plugins
    cpran upgrade oneplugin otherplugin

=cut

# TODO(jja) Break execute into smaller chunks
sub execute {
  my ($self, $opt, $args) = @_;

  $self->app->logger->debug('Executing upgrade');

  if (! scalar @{$args}) {
    $self->app->logger->trace('Processing all installed plugins');
    $args = [
      $self->app->run_command( list => { quiet => 1, installed => 1 } )
    ];
  }

  my @plugins = map {
    require CPrAN::Plugin;
    if (ref $_ eq 'CPrAN::Plugin') { $_ }
    else { CPrAN::Plugin->new( name => $_, cpran => $self->app ) }
  } @{$args};

  if ($self->app->debug) {
    my $n = scalar @{$args};
    $self->app->logger->debug(inflect "<#n:$n> <N:plugin> for processing");
  }

  # Plugins that are not installed cannot be upgraded.
  # @todo will hold the names of the plugins passed as arguments that are
  #   a) valid CPrAN plugin names; and
  #   b) already installed
  #   c) not at the latest version
  my @todo;
  foreach my $plugin (@plugins) {
    if ($plugin->is_installed) {
      if ($plugin->is_cpran) {
        if ($plugin->is_latest // 1) {
          $self->app->logger->debug($plugin->name, 'is already at its latest version')
            if $self->app->debug;
        }
        else {
          push @todo, $plugin;
        }
      }
      else {
        $self->app->logger->debug($plugin->name, 'is not a CPrAN plugin');
      }
    }
    else {
      $self->app->logger->warn($plugin->name, 'is not installed');
    }
  }

  if ($self->app->debug) {
    my $n = scalar @todo;
    $self->app->logger->debug(inflect "<#n:$n> <N:plugin> <V:require> upgrading");
  }

  # Make sure plugins are upgraded in order
  if (scalar @todo) {
    use Array::Utils qw( intersect );

    my @deps = $self->app->run_command( deps => @todo, {
      quiet => 1,
    });
    @todo = intersect(@todo, @deps);
  }

  if (@todo) {
    unless ($self->app->quiet) {
      my $n = scalar @todo;
      print inflect("<#d:$n>The following <N:plugin> will be UPGRADED:"), "\n";
      print '  ', join(' ', map { $_->{name} } @todo), "\n";
      print "Do you want to continue?";
    }

    if ($self->app->_yesno('y')) {
      foreach my $plugin (@todo) {
        print 'Upgrading ', $plugin->name, ' from v',
          $plugin->current, ' to v',
          $plugin->requested, "...\n" unless $self->app->quiet;

        my $success = ($self->git) ?
          $self->git_upgrade($plugin) :
          $self->raw_upgrade($plugin);

        print $plugin->name, ' upgraded successfully', "\n"
          if !$self->app->quiet and $success;
      }
    }
    else {
      print 'Abort', "\n" unless $self->app->quiet;
      exit 1;
    }
  }
  else {
    print 'All plugins up to date', "\n" unless $self->app->quiet;
    exit;
  }
}

sub git_upgrade {
  my ($self, $plugin) = @_;

  try {
    require Git::Repository;
    my $repo;
    try {
      $repo = Git::Repository->new( work_tree => $plugin->root );
    }
    catch {
      $self->app->logger->warn('No git repository at ', $plugin->root);
      $self->app->logger->debug($_);
      exit 1;
    };

    my $head;
    try {
      $head = $repo->run( 'rev-parse' => 'HEAD', { fatal => '!0' } );
    }
    catch {
      $self->app->logger->warn('Could not locate HEAD:', $_);
    };

    try {
      $plugin->fetch unless defined $plugin->url;
      $repo->run( pull => '--tags', $plugin->url, { fatal => '!0' } );
    }
    catch {
      $self->app->logger->warn('Could not fetch from remote');
      $self->app->logger->debug($_);
    };

    my $latest = $plugin->latest;
    my @args = ( '--quiet', $latest->{commit}->{id} );
    push @args, '--force' if defined $self->force;

    try {
      my ($STDOUT, $STDERR) = capture {
        $repo->run( checkout => @args, { fatal => '!0' })
      }
    }
    catch {
      die "Unable to move HEAD. Do you have uncommited local changes? ",
        "Commit or stash them before upgrade to keep them, or discard them with --force.\n";
    };

    $plugin->refresh;
    my $success = 0;
    try { $success = $plugin->test }
    catch {
      chomp;
      $self->app->logger->warn('There were errors while testing:');
      $self->app->logger->warn($_);
    };

    if (defined $success and !$success) {
      if ($self->force) {
        $self->app->logger->warn('Tests failed, but continuing anyway because of --force')
          unless $self->app->quiet;
      }
      else {
        unless ($self->app->quiet) {
          $self->app->logger->warn('Tests failed. Rolling back upgrade of', $plugin->name);
          $self->app->logger->warn('Use --force to ignore this warning');
        }
        $repo->run( reset => '--hard', '--quiet', $head , { fatal => '!0' });

        $self->app->logger->warn('Did not upgrade', $plugin->name)
          unless $self->app->quiet;
        return 0;
      }
    }
    return 1;
  }
  catch {
    $self->app->logger->warn($_);
    $self->app->logger->warn('Aborting');
    exit 1;
  };
}

sub raw_upgrade {
  my ($self, $plugin) = @_;

  $self->app->run_command( remove => $plugin, {
    quiet => 1,
    yes => 1,
  });

  $self->app->run_command( install => $plugin, {
    quiet => 1,
    git => 0,
    yes => 1,
  });

  $plugin->refresh;

  return $plugin->current == $plugin->requested;
}

=head1 OPTIONS

=over

=item B<--git>, B<-g>
=item B<--nogit>

By default, B<upgrade> will try to use B<git> to bring plugins up to date. For
this to work, B<upgrade> needs to be able to find git in the local system, the
B<Git::Repository> module for perl needs to be installed, and the existing
version of the plugin needs to be a git repository.

If these requirements are met and git support is enabled, the upgrade will be
done using git, moving the HEAD to the latest version. This will fail if
there are uncommited local changes. Make sure this command is run with a clean
work environment, or use B<--force> to discard changes.

If this is undesirable (even though the conditions are met), this behaviour can
be disabled with the B<--nogit> option. Be advised that B<this will destroy any
git repositories in the plugin directory>.

=item B<--force>, B<-F>

Attempts to aggresively work around problems. Use at your own risk.

=item B<--test>, B<-T>
=item B<--notest>

These options control execution of the automated tests in each plugin. The
B<--test> option is enabled by default, and will cause these tests to be run.
This can be disabled with the B<--notest> option, which will make the client
skip tests altogether.

This is different from B<--force> in that B<--force> will still run the tests,
but will disregard those that fail.

=back

=cut

=head1 METHODS

=over

=cut

sub process_praat {
  my ($self) = @_;

  try {
    my $praat = $self->app->praat;
    print 'Querying server for latest version...', "\n"
      unless $self->app->quiet;

    if ($praat->latest > $praat->version) {
      unless ($self->app->quiet) {
        print 'Praat will be UPGRADED from ', $praat->version, ' to ', $praat->latest, "\n";
        print 'Do you want to continue?';
      }

      if ($self->_yesno('y')) {
        # TODO: Silence everything _but_ the download progress bar
        $self->app->run_command( install => 'praat', {
          yes => 1,
          reinstall => 1,
          quiet => 1,
        });
      }
    }
    else {
      print 'Praat is already at its latest version (', $praat->version, ")\n";
      exit 0;
    }
  }
  catch {
    chomp;
    $self->app->logger->warn($_);
    $self->app->logger->warn('Could not upgrade Praat');
    exit 1;
  };
  exit 0;
}

=back

=head1 AUTHOR

José Joaquín Atria <jjatria@gmail.com>

=head1 LICENSE

Copyright 2015-2016 José Joaquín Atria

This program is free software; you may redistribute it and/or modify it under
the same terms as Perl itself.

=head1 SEE ALSO

L<CPrAN|cpran>,
L<CPrAN::Plugin|plugin>,
L<CPrAN::Command::deps|deps>,
L<CPrAN::Command::init|init>,
L<CPrAN::Command::install|install>,
L<CPrAN::Command::list|list>,
L<CPrAN::Command::remove|remove>,
L<CPrAN::Command::search|search>,
L<CPrAN::Command::show|show>,
L<CPrAN::Command::test|test>,
L<CPrAN::Command::update|update>

=cut

# VERSION

__PACKAGE__->meta->make_immutable;
no Moose;

1;
