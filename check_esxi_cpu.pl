#!/usr/bin/perl
# Licence : GPL - http://www.fsf.org/licenses/gpl.txt

use strict;
use warnings;
use VMware::VIRuntime;
use VMware::VICredStore;

my $server = "vcenter.ce.corp";
my $url = "https://$server/sdk/vimService";
my $username = "vmwareperl";
my $filename = "/home/nagios/.vmware/credstore/vicredentials.xml";

# options

#my %opts = (
#       vihost => {
#       type => "=s",
#       variable => "vSphere ESXi Host",
#       help => "name of the vSphere ESXi Host is required",
#       required => 1,
#       },
#);

#Opts::add_options(%opts);

# read/validate options
#Opts::parse();
#Opts::validate();

VMware::VICredStore::init(filename => $filename)
	or die ("ERROR: Unable to initialize Credential Store.\n");
my $password = VMware::VICredStore::get_password
		(server => $server, username => $username);
unless (defined ($password)) {
  die "Password not found in Credential Store.\n";
}

#Util::connect();
eval { Vim::login( service_url => $url, user_name => $username, password => $password ) };
if ($@) {
  print "$@";
  exit 3;
}

# Obtain option

# Obtain managed object reference for task manager

my $nagios_port = 5667;
my $nagios_host = "nagios.ce.corp";
my $warning = 95;
my $critical = 98;

my $host_views = Vim::find_entity_views(
				view_type => 'HostSystem',
				properties => [ 'name', 'hardware', 'summary' ]);

open my $nscafh, "|/home/nagios/send_nsca -H $nagios_host -p $nagios_port -d ',' -c /home/nagios/send_nsca.cfg" or die "cannot pipe to send_nsca process, $!";

for my $host_view (@$host_views) {
  my $esxhost_name = $host_view->name;
  $esxhost_name =~ s/.ce.corp//;
  my $cpu_usage = $host_view->summary->quickStats->overallCpuUsage;
  my $cpu_clock = $host_view->hardware->cpuInfo->hz;
  my $num_cpu_cores = $host_view->hardware->cpuInfo->numCpuCores;
  #my $num_cpu_packages = $host_view->hardware->cpuInfo->numCpuPackages;
  my $cpu_capacity = $cpu_clock * $num_cpu_cores / 1000000;
  my $cpu_usage_percentage = $cpu_usage / $cpu_capacity;
  my $cpu_percent = $cpu_usage_percentage * 100;

  my $exitcode;
  if ($cpu_percent < $warning) {
    $exitcode = 0;
  } elsif ($cpu_percent < $critical) {
    $exitcode = 1;
  } else {
    $exitcode = 2;
  }

  printf $nscafh "%s,CPU,%d,CPU usage is %g MHz of %g MHz, %.1f%% | CpuUsage=%g; CpuTotal=%g; CpuPercent=%.1f%%;%g;%g;\n", $esxhost_name, $exitcode, $cpu_usage, $cpu_capacity, $cpu_percent, $cpu_usage, $cpu_capacity, $cpu_percent, $warning, $critical;
}

close $nscafh;
Vim::logout();

__END__
