#!/bin/bash
#set -x

dcli () {
	dash-cli -datadir=/tmp -conf=/etc/dash.conf "$@"
}



# Actually the voting deadline is 1662, but I am trimming the edge here to make sure we get a sample as close as possible to the end of voting.
voting_deadline=1661
# The minute this script started, 00-59
minute=$(date +"%M")
minute=${minute:1:1}
getgovernanceinfo=$(dcli getgovernanceinfo)
nextsuperblock=$(jq -r '.nextsuperblock' <<< "$getgovernanceinfo")
lastsuperblock=$(jq -r '.lastsuperblock' <<< "$getgovernanceinfo")
height=$(dcli getblockcount)


# If we are after voting and just before the Superblock, exit.
((height<(nextsuperblock-voting_deadline)))||exit

# Otherwise are we just after when the superblock was mined?  There is no point running straight after a Superblock, wait awhile.
((height>(lastsuperblock+voting_deadline)))||exit


# To have gotten here must mean the height is well clear of the Superblock.


((minute!=0))&&(((nextsuperblock-voting_deadline-height)>10))&&exit

nice -19 proposal_loader.sh
