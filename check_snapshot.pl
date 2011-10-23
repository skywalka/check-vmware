#!/usr/bin/perl

use strict;
use warnings;
use VMware::VIRuntime;
use VMware::VICredStore;
use Date::Parse;
use Date::Format;
use Net::SMTP;

my ($server, $timelimit, $timecritical);
if (@ARGV == 3) {
  ($server, $timelimit, $timecritical) = @ARGV;
} else {
  print "USAGE: $0 <hostname> <warning time threshold> <critical time threshold>";
  exit 2
}

my $url = "https://$server/sdk/vimService";
my $username = "vmwareperl";
my $filename = "/home/nagios/.vmware/credstore/vicredentials.xml";

# options

#Opts::add_options();

# read/validate options
#Opts::parse();
#Opts::validate();

#Util::connect();

# Obtain option
VMware::VICredStore::init (filename => $filename)
#VMware::VICredStore::init()
        or die ("ERROR: Unable to initialize Credential Store.\n");

my $password = VMware::VICredStore::get_password
                (server => $server, username => $username);
unless (defined ($password)) {
  die "Password not found in Credential Store.\n";
}

# connect to the server
eval { Vim::login( service_url => $url, user_name => $username, password => $password ) };
if ($@) {
  print "$@";
  exit 3;
}

my $serviceinstance = Vim::get_service_instance();
my $current_gmtime_str = $serviceinstance->CurrentTime();
my $current_time_num = str2time($current_gmtime_str);

my $content = Vim::get_service_content();

my $taskMgr = Vim::get_view(mo_ref => $content->taskManager);

# get all VMs in VMware inventory

my $vm_views = Vim::find_entity_views(
				view_type => 'VirtualMachine',
				filter => { 'config.template' => 'false' },
				properties => [ 'name', 'snapshot' ]);

my %vm_snap_data;
my $final_message;
my $code;

# get a list of VMs which have snapshots
for my $vm (@$vm_views) {
  my $snapshots = $vm->snapshot;
  if (defined $snapshots) {
    my $vmname = $vm->name;
    $vm_snap_data{$vmname} = get_snapshot_detail($vmname, $snapshots);
  }
}

#print Dumper(\%vm_snap_data);

if ((keys %vm_snap_data) == 0) {
  $final_message = "No snapshot.\n";
  $code = 0;
} else {
# get a list of VMs which have snapshots older than 6 days
  for (keys %vm_snap_data) {
    delete $vm_snap_data{$_} unless (keys %{$vm_snap_data{$_}});
  }

# set up output message and exit code for Nagios alerts
  if ((keys %vm_snap_data) >= 1) {
    my $vmmessage;
    for my $vm (keys %vm_snap_data) {
      my $snapmessage;
      for my $snapid (keys %{$vm_snap_data{$vm}}) {
        my $starttime = $vm_snap_data{$vm}->{$snapid}->{'taskstarttime'};
        my $endtime = $vm_snap_data{$vm}->{$snapid}->{'taskendtime'};
        my $mailtime = $vm_snap_data{$vm}->{$snapid}->{'emailtime'};
        my $period = $vm_snap_data{$vm}->{$snapid}->{'snapperiod'};
        my $createtime = $vm_snap_data{$vm}->{$snapid}->{'createtime'};
        my $snapname = $vm_snap_data{$vm}->{$snapid}->{'snapname'};
        my $tasknumber = $vm_snap_data{$vm}->{$snapid}->{'tasknumber'};
        my $taskref = $vm_snap_data{$vm}->{$snapid}->{'taskrecords'};
        my $message;
        if ($tasknumber == 0) {
          $message = "$vm,$period days,unknown user";
        } elsif ($tasknumber == 1) {
            if (defined $taskref->[0]->reason->userName) {
              (my $snap_user = $taskref->[0]->reason->userName) =~ s/CE\\[aA]?//;
              $snap_user .= '@ce.com.au';
              $message = "$vm,$period days,$snap_user";
#              $snap_user = 'xian.zhang@ce.com.au';
#              print "period is $period\n";
#              print "sub time is $mailtime\n";
              if ($period >= $timecritical) {
                send_mail($snap_user, $period, $vm, $createtime, $snapname);
              } elsif ($period >= $timelimit) {
                if ($mailtime <= 0.041666667) {
                  send_mail($snap_user, $period, $vm, $createtime, $snapname);
                }
              }
            } else {
                $message = "$vm,$period days,unknown user";
            }
        } else {
             my @task_for_snapshot = grep {$_->result->value eq $snapid} @{$taskref};
             if (@task_for_snapshot == 0) {
               $message = "$vm,$period days,unknown user";
             } elsif (@task_for_snapshot == 1) {
                 if (defined $task_for_snapshot[0]->reason->userName) {
                   (my $snap_user = $task_for_snapshot[0]->reason->userName) =~ s/CE\\[aA]?//;
                   $snap_user .= '@ce.com.au';
                   $message = "$vm,$period days,$snap_user";
#                   $snap_user = 'xian.zhang@ce.com.au';
#                    print "sub time is $mailtime\n";
                   if ($period >= $timecritical) {
                     send_mail($snap_user, $period, $vm, $createtime, $snapname);
                   } elsif ($period >= $timelimit) {
                     if ($mailtime <= 0.041666667) {
                       send_mail($snap_user, $period, $vm, $createtime, $snapname);
                     }
                   }
                 } else {
                     $message = "$vm,$period days,unknown user";
                 }
             } else {
                 $message = "$vm,$period days,unknown user";
             }
        }
        $snapmessage .= $message;
        $snapmessage .= '*';
      }
      $vmmessage .= $snapmessage;
    }
    $final_message .= $vmmessage;
    $code = 1;
  } else {
    $final_message = "No snapshot is over $timelimit days old.\n";
    $code = 0;
  }
}

$final_message =~ s/\*$//;
print $final_message;

#Util::disconnect();
Vim::logout();

exit $code;

sub get_snapshot_detail {
    my $vmname = shift;
    my $snapshots = shift;
    my %snap_data_str;
    for my $snapshot (@{$snapshots->rootSnapshotList}) {
      my $snapshot_identity = $snapshot->snapshot->value;
      $snap_data_str{$snapshot_identity} = child_snapshot($vmname, $snapshot);
    }
    for (keys %snap_data_str) {
      if ($snap_data_str{$_}->{'snapperiod'} < $timelimit) {
        delete $snap_data_str{$_};
      }
    }
    return \%snap_data_str;
}

sub child_snapshot {
      my $vmname = shift;
      my $snapshot = shift;
      my %snap_details;
      my $snapshot_id = $snapshot->snapshot->value;
      my $snapshot_name = $snapshot->name;
      my $create_time = $snapshot->createTime;
      my $create_time_number = str2time($create_time);              # get gm time (in number) when the snapshot was created 
      my $time_begin = $create_time_number - 60;                      # gm time in number
      my $time_end = $create_time_number + 60;                       # gm time in number
      (my $ss = $time_begin) =~ s/^.+\././;
      my @gm_str_begin = gmtime($time_begin);
      my @gm_str_end = gmtime($time_end);
#      my $serviceinstance = Vim::get_service_instance();
#      my $current_gmtime_str = $serviceinstance->CurrentTime();
#      my $current_time_num = str2time($current_gmtime_str);
#      (my $time_diff = ($current_time_num - $create_time_number) / 86400) =~ s/\.\d+//;
      my $time_duration = ($current_time_num - $create_time_number) / 86400;
      my ($time_diff, $time_sub_day) = split /\./, $time_duration;
      $time_sub_day = $time_duration - $time_diff;
      my $gm_string_begin = strftime("%Y-%m-%dT%X", @gm_str_begin) . $ss;
      my $gm_string_end = strftime("%Y-%m-%dT%X", @gm_str_end) . $ss;

      my $task_record = get_user_name($vmname, $gm_string_begin, $gm_string_end);
      my @task_records = grep {$_->descriptionId eq 'VirtualMachine.createSnapshot'} @{$task_record};
      my $task_number = @task_records;

      $snap_details{'emailtime'} = $time_sub_day;
      $snap_details{'snapperiod'} = $time_diff;
      $snap_details{'taskstarttime'} = $gm_string_begin;
      $snap_details{'taskendtime'} = $gm_string_end;
      $snap_details{'createtime'} = $create_time;
      $snap_details{'snapname'} = $snapshot_name;
      $snap_details{'tasknumber'} = $task_number;
      $snap_details{'taskrecords'} = \@task_records;
      return \%snap_details;
}

sub get_user_name {
  my $vm_name = shift;
  my $snap_create_time = shift;
  my $snap_start_time = shift;
  my $vm_view = Vim::find_entity_view(
				view_type => 'VirtualMachine',
				filter => { 'name' => $vm_name });

my $timetype = TaskFilterSpecTimeOption->new('startedTime');

my $shtime = TaskFilterSpecByTime->new(beginTime => $snap_create_time,
                                        endTime => $snap_start_time,
                                        timeType => $timetype);

#my $shtime = TaskFilterSpecByTime->new(timeType => $timetype);

my $recursion = TaskFilterSpecRecursionOption->new('self');

my $entity = TaskFilterSpecByEntity->new(entity => $vm_view,
					recursion => $recursion);


my $task_filter_spec = TaskFilterSpec->new(entity => $entity,
					time => $shtime);

my $task_history_collector = $taskMgr->CreateCollectorForTasks(filter => $task_filter_spec);

my $task_history_collector_view = Vim::get_view(mo_ref => $task_history_collector);

$task_history_collector_view->ResetCollector();

my $lastpages = $task_history_collector_view->latestPage;

return $lastpages;

}

sub send_mail {
  my $snapuser = shift;
  my $period = shift;
  my $vm = shift;
  my $create_time = shift;
  my $snapshot_name = shift;
  my $smtpgateway = 'smtp.ce.corp';
  my $smtp = Net::SMTP->new($smtpgateway);
#  my $nagiosuser = 'sysadm@ce.com.au';
#  my $vmwareadmin = 'bis.helpdesk@ce.com.au';
  
  # -- Enter email FROM below.   --
#  $smtp->mail($nagiosuser);
  $smtp->mail($snapuser);

  #  -- Enter email TO below --
  $smtp->to($snapuser);
#  $smtp->cc($vmwareadmin);

  $smtp->data();

  #This part creates the SMTP headers you see
  $smtp->datasend("To: $snapuser\n");
#  $smtp->datasend("Cc: $vmwareadmin\n");
#  $smtp->datasend("From: $nagiosuser\n");
  $smtp->datasend("From: $snapuser\n");
  $smtp->datasend("Subject: Please review your VMware snapshot on $vm\n");
  $smtp->datasend("content-Type: text/plain \n");

  # line break to separate headers from message body
  $smtp->datasend("\n");
  $smtp->datasend("The snapshot, called $snapshot_name, that you took on $create_time on $vm is now $period days old, please delete it as soon as you can.\n");
  $smtp->datasend("\n");
  $smtp->datasend("\n");
  $smtp->datasend("Please talk to VMware administrator if you need it longer.\n");
  $smtp->dataend();

$smtp->quit();

}
