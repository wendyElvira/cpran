# ABSTRACT: search among available CPrAN plugins
package CPrAN::Command::search;

use CPrAN -command;

use strict;
use warnings;
use diagnostics;
use Data::Dumper;
use Encode qw(encode decode);
binmode STDOUT, ':utf8';

sub opt_spec {
  return (
    [ "name|n",        "search in plugin name" ],
    [ "description|d", "search in description" ],
    [ "installed|i",   "only consider installed plugins" ],
    [ "debug",         "show debug messages" ],
  );
}

sub validate_args {
  my ($self, $opt, $args) = @_;

  $args->[0] = '.*' unless @{$args};
}

sub execute {
  my ($self, $opt, $args) = @_;

  use Path::Class;
  use Text::Table;

  my $output;
  my @files;
  if ($opt->{installed}) {
    $output = Text::Table->new(
      "Name", "Local", "Remote", "Description"
    );
    my @all_files = dir( $CPrAN::PRAAT )->children;
    map {
      if (CPrAN::is_cpran($opt, $_)) {
        my $name = $_->basename;
        $name =~ s/^plugin_//;
        push @files, $name;
      }
    } @all_files;
  }
  else {
    $output = Text::Table->new(
      "Name", "Version", "Description"
    );
    @files = map {
      $_->basename;
    } dir( $CPrAN::ROOT )->children;
  }

  map {
    $output->add(make_row($opt, $_)) if (/$args->[0]/);
  } sort @files;
  print $output;
}

sub make_row {
  my ($opt, $name) = @_;

  use YAML::XS;
  use File::Slurp;

  my $yaml;
  my $content;
  my $remote_file = file($CPrAN::ROOT, $name);
  if ($opt->{installed}) {
    my $local_file  = file($CPrAN::PRAAT, 'plugin_' . $name, 'cpran.yaml');

    $content = read_file($local_file->stringify);
    $yaml = Load( $content );

    my $name = $yaml->{Plugin};
    my $local_version = $yaml->{Version};
    my $description = $yaml->{Description}->{Short};

    $content = read_file($remote_file->stringify);
    $yaml = Load( $content );

    my $remote_version = $yaml->{Version};

    return ($name, $local_version, $remote_version, $description);
  }
  else {
    $content = read_file($remote_file->stringify);
    $yaml = Load( $content );

    my $name = $yaml->{Plugin};
    my $remote_version = $yaml->{Version};
    my $description = $yaml->{Description}->{Short};

    return ($name, $remote_version, $description);
  }
}

1;
