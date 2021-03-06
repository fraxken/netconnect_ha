use strict;
use warnings;
use lib "D:/apps/Nimsoft/perllib";
use lib "D:/apps/Nimsoft/Perl64/lib/Win32API";

use Nimbus::API;
use Nimbus::CFG;
use Nimbus::PDS;

use perluim::logger;
use perluim::main;
use perluim::utils;
use perluim::filemap;
use core::netconnect_ha;

my $probeName       = "netconnect_ha";
my $probeVersion    = "1.0";
my $time = time();

# Declare variables
my ($Logger,$UIM,$Execution_Date);
my ($Domain,$OutputCache,$OutputDirectory,$Login,$Password,$Daemon_mode,$Netconnect_online,$SyncPath,$Nim_ADDR,$localMap,$LogDirectory,$Daemon_timeout);
my $Main_executed = 0; 

$SIG{__DIE__} = \&dieHandler;
# Create log file
$Logger = new perluim::logger({
    file => "$probeName.log",
    level => 6
});
$Logger->log(3,"$probeName started at $time!");

readConfiguration();

if(not defined $Nim_ADDR) {
    die("Please define configuration/nim_addr");
}

# Create framework
nimLogin("$Login","$Password") if defined($Password) && defined($Password);
$UIM            = new perluim::main("$Domain");
$Logger->cleanDirectory("$OutputDirectory",$OutputCache); 

sub readConfiguration {
    $Logger->log(3,"Read configuration...");
    my $CFG              = Nimbus::CFG->new("$probeName.cfg");
    $Domain              = $CFG->{"setup"}->{"domain"};
    $OutputDirectory     = $CFG->{"setup"}->{"output_directory"} || "output";
    $OutputCache         = $CFG->{"setup"}->{"output_cache_time"} || 345600;
    $Login               = $CFG->{"setup"}->{"nim_login"};
    $Password            = $CFG->{"setup"}->{"nim_password"};

    $Daemon_mode         = $CFG->{"configuration"}->{"daemon_mode"} || "yes";
    $Daemon_timeout      = $CFG->{"configuration"}->{"daemon_timeout"} || 120;
    $Netconnect_online   = $CFG->{"configuration"}->{"netconnect_online"} || "no";
    $SyncPath            = $CFG->{"configuration"}->{"sync_path"} || "storage";
    $Nim_ADDR            = $CFG->{"configuration"}->{"nim_addr"};

    $Execution_Date = perluim::utils::getDate();
    $LogDirectory = "$OutputDirectory/$Execution_Date";
    perluim::utils::createDirectory($LogDirectory);
    perluim::utils::createDirectory("$SyncPath");
}

# Get remote robot!
sub getRemote {
    my ($LocalRobot) = @_; 
    my ($RC,$RemoteRobot) = $UIM->getLocalRobot($Nim_ADDR);
    if($RC == NIME_OK) {
        return NIME_OK,$RemoteRobot;
    }
    return $RC,undef;
}

# Main method!
sub main {

    {
        my $MainExecute = perluim::utils::getDate();
        $Logger->copy("output/$MainExecute");
    }
    $localMap = new perluim::filemap("$SyncPath/state.cfg");

    # Get local robot!
    my ($RC,$LocalRobot,$RemoteRobot);
    $Main_executed = 1;
    ($RC,$LocalRobot) = $UIM->getLocalRobot(); 
    if($RC == NIME_OK) {
        $Logger->log(6,"Sucessfully get local robot!");
        ($RC,$RemoteRobot) = getRemote($LocalRobot);
        my $HA_Manager = new core::netconnect_ha({
            localRobot => $LocalRobot,
            remoteRobot => $RemoteRobot,
            logger => $Logger,
            path => $SyncPath
        });

        # Intermediate netconnect checkup!
        if($Netconnect_online eq "yes" && $RC == NIME_OK) {
            $Logger->log(3,"Check remote net_connect");
            $RC = $HA_Manager->checkRemoteNetconnect();
            if($RC != NIME_OK) {
                $Logger->log(2,"Remote net_connect seem to be offline!");
            }
        }

        if( $RC == NIME_OK ) {
            
            $Logger->log(6,"Sucessfully get remote robot!");
            if($localMap->has("HA")) {
                my $A_RC = $HA_Manager->HA_Disabling();
                if($A_RC == NIME_OK) {
                    $localMap->delete("HA");
                    $Logger->log(6,"HA Has been disabled succesfully!");
                }
                else {
                    $Logger->log(1,"Failed to disabled HA");
                }
            }
            my $get_rc = $HA_Manager->getCFG();
            if(not $get_rc) {
                $Logger->log(2,"Failed to get CFG from local and remote robot!");
            }
        }
        else {
            $Logger->log(2,"Failed to get remote hub!");
            if(not $localMap->has("HA")) {
                my $A_RC = $HA_Manager->HA_Activation();
                if($A_RC) {
                    $Logger->log(6,"HA succesfully activated!");
                    $localMap->set("HA",{});
                }
                else {
                    $Logger->log(1,"Failed to active HA with RC => $A_RC");
                }
            }
            else {
                $Logger->log(2,"HA is already activated!");
            }
        }

    }
    else {
        $Logger->log(1,"Failed to get local robot!");
    }

    # Write local map to disk!
    $localMap->writeToDisk();
    $Main_executed = 0;

}

sub dieHandler {
    my ($err) = @_;
    $localMap->writeToDisk();
    $Logger->finalTime($time);
	$Logger->log(0,"Program is exiting abnormally : $err");
    $| = 1; # Buffer I/O fix
    sleep(2);
    {
        my $MainExecute = perluim::utils::getDate();
        $Logger->copy("output/$MainExecute");
    }
}

if($Daemon_mode eq "yes") {

    sub isHA {
        my ($hMsg) = @_;
        $Logger->log(5,"---------------------------------");
        my $HA_Value = $localMap->has('HA');
        $Logger->log(3,"isHA callback triggered with HA Value => $HA_Value");
        my $PDS = pdsCreate();
	    pdsPut_PCH ($PDS,"state","$HA_Value");
        nimSendReply($hMsg,NIME_OK,$PDS);
    }

    sub execute {
        my ($hMsg) = @_;
        my $PDS = pdsCreate();
        $Logger->log(5,"---------------------------------");

        if($Main_executed) {
            pdsPut_PCH ($PDS,"error","Main is already executed!");
            nimSendReply($hMsg,NIME_ERROR,$PDS);
        }
        else {
            main();
            nimSendReply($hMsg,NIME_OK,$PDS);
        }
    }

    sub timeout {
        $Logger->log(5,"---------------------------------");
        $localMap = new perluim::filemap("$SyncPath/state.cfg");

        if($localMap->has("timecount")) {
            my $Params = $localMap->getParams("timecount"); 
            $Logger->log(3,"Timeout counter interval => $Params->{count} / $Daemon_timeout");
            if($Params->{count} >= $Daemon_timeout) {
                $localMap->set("timecount",{
                    count => 0
                });
                $localMap->writeToDisk();
                main();
            }
            else {
                my $nCount = $Params->{count} + 1;
                $localMap->set("timecount",{
                    count => $nCount
                });
                $localMap->writeToDisk();
            }
        }
        else {
            $localMap->set("timecount",{
                count => 0
            });
            $localMap->writeToDisk();
            main();
        }
    }

    sub restart {
        readConfiguration();
    }

    my $sess = Nimbus::Session->new("netconnect_ha");
    $sess->setInfo("$probeVersion", "netconnect high availability");

    if ($sess->server(NIMPORT_ANY,\&timeout,\&restart) == 0 ) {
        $sess->addCallback("isHA");
        $sess->addCallback("execute");
        $sess->dispatch();
    }

}
else {
    main();
}

# Close script!
$Logger->finalTime($time);
$Logger->copyTo($LogDirectory);
$Logger->close();
