#!/usr/bin/perl
use strict;
use warnings;
use VMware::VIRuntime;
use VMware::VICredStore;

my $server = "vcenter.ce.corp";
my $url = "https://$server/sdk/vimService";
my $username = "vmwareperl";
my $warning = 1;
my $critical = 2;
my $unknown = 3;
my $good = 0;
my $nagios_server = "syd1mon01.ce.corp";
my $nagios_port = 5667;
my %faults = ();
my @esxhosts;

my $filename = "/home/nagios/.vmware/credstore/vicredentials.xml";

# options

#my %opts = (
#       vmname => {
#       type => "=s",
#       varitable => "Virtual Machine",
#       help => "name of the virtual machine is required",
#       required => 1,
#       },
#);

#Opts::add_options();

# read/validate options
#Opts::parse();
#Opts::validate();


VMware::VICredStore::init(filename => $filename) or die_with_code($unknown, "Can't initiate credential store session, $!");
my $password = VMware::VICredStore::get_password
               (server => $server, username => $username);
unless (defined ($password)) {
  die_with_code($unknown, "Can't get password, $!");
}

Vim::login(service_url => $url, user_name => $username, password => $password);

my $host_views = Vim::find_entity_views(
                       view_type => "HostSystem",
                       properties => [ "name", "configManager" ],);

for my $host (@$host_views) {
  my $numeric = 1;
  my $nonum = 0;

  my $host_name = $host->name;
  push @esxhosts, $host_name;
  my $health_status_ref = $host->configManager->healthStatusSystem;
  my $hhss_view = Vim::get_view(
                     mo_ref => $health_status_ref
                     );

  my $HealthSystemRuntime = $hhss_view->runtime;
  if (defined $HealthSystemRuntime) {
################################################
# hardwareStatusInfo section
################################################
    my $HostHardwareStatusInfo = $HealthSystemRuntime->hardwareStatusInfo;
    my $cpuStatusInfo = $HostHardwareStatusInfo->cpuStatusInfo;
    my $memStatusInfo = $HostHardwareStatusInfo->memoryStatusInfo;
    my $storageStatusInfo = $HostHardwareStatusInfo->storageStatusInfo;
    if (defined $cpuStatusInfo) {
      hw_st_chk($cpuStatusInfo, $host_name, $nonum);
    }      
    if (defined $memStatusInfo) {
      hw_st_chk($memStatusInfo, $host_name, $nonum);
    }
    if (defined $storageStatusInfo) {
      hw_st_chk($storageStatusInfo, $host_name, $nonum);
    }

################################################
# systemHealthInfo section
################################################
    my $numericSensorInfo = $HealthSystemRuntime->systemHealthInfo->numericSensorInfo;
    if (defined $numericSensorInfo) {
      hw_st_chk($numericSensorInfo, $host_name, $numeric);
    }
  }
}

open my $nscafh, "|/home/nagios/send_nsca -H $nagios_server -p $nagios_port -d ',' -c /home/nagios/send_nsca.cfg" or die_with_code($unknown, "Can't pipe to send_nsca process, $!" );

for my $esxname (@esxhosts) {
  my $description;
  my $nagios_str;
  my $devname;
  my $nagios_code;
  if (exists $faults{$esxname}) {
    if (exists $faults{$esxname}->{$critical}) {
      $nagios_code = $critical;
      $nagios_str = get_nagios_result($faults{$esxname}->{$critical});
    }
    elsif (exists $faults{$esxname}->{$warning}) {
      $nagios_code = $warning;
      $nagios_str = get_nagios_result($faults{$esxname}->{$warning});
    }
    else {
#     to prevent unnecessary Nagios alerts, unknown state has been treated as OK
      $description = "Hardware OK";
      $nagios_code = $good;
      $nagios_str = $description;
    }
      $nagios_str =~ s/\s*\*\s*$//;
  }
  else {
    $description = "Hardware OK";
    $nagios_code = $good;
    $nagios_str = $description;
  }

$esxname =~ s/\.ce\.corp//;
#print "$esxname,hardware check,$nagios_code,$nagios_str\n";
print $nscafh "$esxname,hardware check,$nagios_code,$nagios_str\n";

}

close $nscafh;
Vim::logout();


sub die_with_code {
  my $code = shift;
  my $message = shift;
  print "$message\n";
  exit $code;
}

sub hw_st_chk {
  my ($hw_refs, $host_name, $numeric) = @_;
  my $hw_status;

  if ($numeric == 1) {
    $hw_status = "healthState";
  }
  elsif ($numeric == 0) {
    $hw_status = "status";
  }
  else {
  }

  for my $hw_ref (@$hw_refs) {
      next if $hw_ref->$hw_status->key =~ /^[Gg]reen$/;
      my $devname = $hw_ref->name;
      if ($hw_ref->$hw_status->key =~ /^[Yy]ellow$/) {
        push @{$faults{$host_name}->{$warning}}, {
                                                   devname => $devname,
                                                   summary => $hw_ref->$hw_status->summary,
                                                 }

      }
      elsif ($hw_ref->$hw_status->key =~ /^[Rr]ed$/) {
        push @{$faults{$host_name}->{$critical}}, {
                                                    devname => $devname,
                                                    summary => $hw_ref->$hw_status->summary,
                                                  }

      }
      else {
        push @{$faults{$host_name}->{$unknown}}, {
                                                   devname => $devname,
                                                   summary => $hw_ref->$hw_status->summary,
                                                 }

      }
    }
 
}

sub get_nagios_result {
  my $faults = shift;
  my $nagios_str;
  
  for my $err (@$faults) {
    my $description = $err->{summary};
    my $devname = $err->{devname};
    my $nagios_tmp = $devname . "->" . $description . " * ";
    $nagios_str .= $nagios_tmp;
  }

  return $nagios_str;
}

