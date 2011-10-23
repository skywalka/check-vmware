#!/usr/bin/perl

use strict;
use warnings;
use VMware::VIRuntime;
use VMware::VICredStore;

my $server = "vcenter.ce.corp";
my $url = "https://$server/sdk/vimService";
my $username = "vmwareperl";
my $filename = "/home/nagios/.vmware/credstore/vicredentials.xml";
my $dcname = "DC-01 Corporate Express";    # this script only support one datacenter at this version

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

my $nagios_port = 5667;
my $nagios_host = "nagios.ce.corp";
my $local_datastore = "datastore1";
my $nas_datastore = "isilon_datastore";

my %lun_threshold = (
	"0042_131" => {
		warning => 90,
		critical => 95,
	},
	"0042_13B" => {
		warning => 90,
		critical => 95,
	},
	"0042_151" => {
		warning => 90,
		critical => 95,
	},
	"4208_4a_r1" => {
		warning => 90,
		critical => 95,
	},
	"4208_5c_r1" => {
		warning => 90,
		critical => 95,
	},
	"4208_6e" => {
		warning => 90,
		critical => 95,
	},
	"4208_80_R1" => {
		warning => 90,
		critical => 95,
	},
	"4208_4A_R1" => {
		warning => 94,
		critical => 95,
	},
	"4208_a4" => {
		warning => 90,
		critical => 95,
	},
	"4208_b6" => {
		warning => 90,
		critical => 95,
	},
	"4208_c8" => {
		warning => 92,
		critical => 97,
	},
	"4208_da" => {
		warning => 90,
		critical => 95,
	},
	"4208_135_syd1sql01_tempdb" => {
		warning => 90,
		critical => 95,
	},
	"4208_13d_syd1sql01_log" => {
		warning => 90,
		critical => 95,
	},
	"4208_140_syd1sql01_db" => {
		warning => 95,
		critical => 97,
	},
	"4208_138_syd1sql02_tempdb" => {
		warning => 90,
		critical => 95,
	},
	"4208_131_syd1sql02_log" => {
		warning => 95,
		critical => 97,
	},
	"4208_f0_syd1sql02_db" => {
		warning => 90,
		critical => 95,
	},
	"4208_156_syd1app42" => {
		warning => 96,
		critical => 98,
	},
	"4208_205_r1_syd1exc13_db" => {
		warning => 97,
		critical => 98,
	},
	"4208_221_r1_syd1exc13_log" => {
		warning => 90,
		critical => 95,
	},
	"4208_235_r1_syd1exc13_db" => {
		warning => 98,
		critical => 99,
	},
	"4208_213_r1_syd1exc14_db" => {
		warning => 97,
		critical => 98,
	},
	"4208_224_r1_syd1exc14_log" => {
		warning => 90,
		critical => 95,
	},
	"4208_283_r1_syd1exc14_db" => {
		warning => 98,
		critical => 99,
	},
	"4785_145" => {
		warning => 95,
		critical => 97,
	},
	"4785_B6" => {
		warning => 95,
		critical => 97,
	},
	"4785_EC" => {
		warning => 90,
		critical => 95,
	},
	"4785_92" => {
		warning => 90,
		critical => 95,
	},
	"4785_a4" => {
		warning => 90,
		critical => 95,
	},
	"4785_b6" => {
		warning => 90,
		critical => 95,
	},
	"4785_c8" => {
		warning => 90,
		critical => 95,
	},
	"4785_da" => {
		warning => 90,
		critical => 95,
	},
	"4208_243" => {
		warning => 90,
		critical => 95,
	},
	"4208_1ec" => {
		warning => 90,
		critical => 95,
	},
);

# Obtain option

# Obtain managed object reference for task manager

my $datacenter_view = Vim::find_entity_view(
				view_type => 'Datacenter',
                                filter => { 'name' => $dcname },
				properties => [ 'datastore' ]);

my $datastores_views = Vim::get_views(mo_ref_array => $datacenter_view->datastore);
my @datastores_view = grep { $_->name !~ /$local_datastore$|$nas_datastore/ } @$datastores_views;
open my $nscafh, "|/home/nagios/send_nsca -H $nagios_host -p $nagios_port -d ',' -c /home/nagios/send_nsca.cfg" or die "cannot pipe to send_nsca process, $!";

for my $datastore (@datastores_view) {
  my $datastore_name = $datastore->name;
  my $disk_capacity = $datastore->summary->capacity / 1073741824;
  my $disk_free = $datastore->summary->freeSpace / 1073741824;
  my $disk_uncommitted = $datastore->summary->uncommitted;
  my $disk_usage =  $disk_capacity - $disk_free;
  if (defined $disk_uncommitted) {
     $disk_uncommitted /= 1073741824;
  }
  else {
     $disk_uncommitted = 0;
  }
  my $disk_provisioned = $disk_capacity - $disk_free + $disk_uncommitted;
  my ($disk_usage_percentage, $disk_percent); 
  eval { $disk_usage_percentage = $disk_usage / $disk_capacity;
         $disk_percent = $disk_usage_percentage * 100;
  };
  next if $@;
  my $exitcode;
  my $warning_num;
  my $critical_num;
  if (exists $lun_threshold{"$datastore_name"}) { 
    $warning_num = $lun_threshold{"$datastore_name"}->{"warning"};
    $critical_num = $lun_threshold{"$datastore_name"}->{"critical"};
  } else {
    $warning_num = 90;
    $critical_num = 95;
  }
  if ($disk_percent < $warning_num) {
    $exitcode = 0;
  } elsif ($disk_percent < $critical_num) {
    $exitcode = 1;
  } else {
    $exitcode = 2;
  }

  printf $nscafh "syd1vvc01,LUN:%s,%d,disk space usage is %g GB of %g GB, %.1f%%, %g GB Provisioned | DiskUsage=%g; DiskTotal=%g; DiskPercent=%.1f%%;%g;%g; DiskProvisioned=%g;\n", $datastore_name, $exitcode, $disk_usage, $disk_capacity, $disk_percent, $disk_provisioned, $disk_usage, $disk_capacity, $disk_percent, $warning_num, $critical_num, $disk_provisioned;

}

close $nscafh;

Vim::logout();

__END__

