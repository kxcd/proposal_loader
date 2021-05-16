#!/bin/bash
#set -x

VERSION="$0 (v0.4.0 build date 202104290000)"
DATABASE_VERSION=1
DATADIR="$HOME/.dash_proposal_loader"




usage(){
	msg="$VERSION\n"
	msg+="This program will collect proposal information in the DASH network\n"
	msg+="and store it to a sqlite database.\n\n"
	msg+="Usage: $0 [ options ] \n\n"
	msg+="Options:\n"
	msg+="	-help				This help text.\n"
	msg+="	-datadir [path_to_dir]		The location to save the data in, default location is $DATADIR"
	echo -e "$msg"
}

# Parse commandline options and set flags.
while (( $# > 0 ))
do
key="$1"

case $key in
	-h|-help|--help)
		usage
		exit 0
		;;
	-datadir)
		DATADIR="$2"
		shift;shift
		;;
	*)
		echo -e "[$$] $VERSION\n[$$] Unknown parameter $1\n[$$] Please check help page with $0 -help" >&2
		exit 1
		shift
		;;
esac
done

echo "[$$] Starting $VERSION." >&2



# Now we are safe to use variables eg DATADIR, so let's compute a database_file
DATABASE_FILE="$DATADIR/database/proposals.db"


# Checks that the required software is installed on this machine.
check_dependencies(){
	unset progs
	jq --help >/dev/null 2>&1 || progs+=" jq"
	sqlite3 -version >/dev/null 2>&1 || progs+=" sqlite3"

	if [[ -n $progs ]];then
		msg="[$$] $VERSION\n[$$] Missing applications on your system, please run\n\n"
		msg+="[$$] sudo apt install $progs\n\n[$$] before running this program again."
		echo -e "$msg" >&2
		exit 1
	fi
}


make_datadir(){

	if [[ ! -d "$DATADIR" ]];then
		mkdir -p "$DATADIR"/{database,logs}
		if (( $? != 0 ));then
			echo "[$$] Error creating datadir at $DATADIR exiting..." >&2
			exit 2
		fi
	fi
}


# A safe wrapper around SQL access to help with contention in concurrent environments.
execute_sql(){

	[[ -z $1 ]] && return
	for((i=1; i<100; i++));do
		sqlite3 "$DATABASE_FILE" <<< "$1" 2>>"$DATADIR"/logs/sqlite.log && return
		retval=$?
		echo "[$$] Failed query attempt number: $i." >>"$DATADIR"/logs/sqlite.log
		delay=1
		# Add extra delay time after every 10 failed shots.
		(($((i % 10)) == 0)) && delay=$((delay+RANDOM%100))
		sleep "$delay"
	done
	echo -e "[$$] The failed query vvvvv\n$1\n[$$] ^^^^^ The above query did not succeed after $i attempts, aborting..." >>"$DATADIR"/logs/sqlite.log
	return $retval
}



initialise_database(){

	# Database exists, no need to create it.
	[[ -f "$DATABASE_FILE" ]] && return

	# Create db objects.
	sql="PRAGMA foreign_keys = ON;"
	sql+="create table db_version(version integer primary key not null);"
	sql+="insert into db_version values(1);"
	sql+="create table proposals(run_date integer not null check(run_date>=0), ProposalHash text primary key not null, CollateralHash text not null, ObjectType integer not null, CreationTime integer not null, fBlockchainValidity text not null, IsValidReason text, fCachedValid text not null, fCachedFunding text not null, fCachedDelete text not null, fCachedEndorsed text not null, end_epoch integer not null, name text nor null, payment_address text not null, payment_amount real not null check(payment_amount>=0), start_epoch integer not null, Type integer not null, url text);"
	sql+="create unique index idx_ProposalHash on proposals(ProposalHash);"
	sql+="create table votes(run_date integer not null check(run_date>=0),ProposalHash text not null,AbsoluteYesCount integer not null, YesCount integer not null, NoCount integer not null, AbstainCount integer not null,foreign key(ProposalHash)references proposals(ProposalHash), primary key(run_date,ProposalHash));"
	sql+="create index idx_vote_ProposalHash on votes(ProposalHash);"
	sql+="create table masternodes (run_date integer primary key not null check(run_date>=0), height integer not null check(height>=0), collateralised_masternode_count integer not null check(collateralised_masternode_count>=0),enabled_masternode_count integer not null check(enabled_masternode_count>=0));"
	sql+="create index idx_masternode_rundate on masternodes(run_date);"
	sql+="create trigger delete_proposal before delete on proposals for each row begin delete from votes where ProposalHash=old.ProposalHash;end;"
	
	execute_sql "$sql"
	if (( $? != 0 ));then
		echo "[$$] Cannot initialise sqlite database at $DATABASE_FILE exiting..." >&2
		exit 4
	fi
}




# Make sure the version is at the latest version and upgrade the schema if possible.
check_and_upgrade_database(){

	db_version=$(execute_sql "select version from db_version;")
	if (( db_version != DATABASE_VERSION ));then
		echo "[$$] The database version is $db_version was expecting $DATABASE_VERSION" >&2
		exit 5;
	fi
	proposals=$(execute_sql "select count(1) from proposals;")
	votes=$(execute_sql "select count(distinct run_date) from votes;")
	echo "[$$] Database is up to date and contains $proposals proposals and $votes snapshot(s)." >&2

}


parseAndLoadProposals(){

	run_date=$(date +"%Y%m%d%H%M%S")
	height=$(dash-cli getblockcount)
	masternode=$(dash-cli masternode count)
	collateralised_masternode_count=$(jq -r '.total'<<<"$masternode")
	enabled_masternode_count=$(jq -r '.enabled'<<<"$masternode")

	gobject=$(dash-cli gobject list)
	echo "[$$] Parsing proposals for run_date = $run_date..." >&2
	# I want to make all the DB changes in one go to make sure the database is consistent in case of power failure.
	sql="begin transaction;"

	for hash in $(echo "$gobject"|grep -i -o '"[1234567890abcdef]*": {'|grep -i -o '[1234567890abcdef]*');do
		ProposalHash=$(jq -r ".\"$hash\".Hash"<<<"$gobject")
		CollateralHash=$(jq -r ".\"$hash\".CollateralHash"<<<"$gobject")
		ObjectType=$(jq -r ".\"$hash\".ObjectType"<<<"$gobject")
		CreationTime=$(jq -r ".\"$hash\".CreationTime"<<<"$gobject")
		AbsoluteYesCount=$(jq -r ".\"$hash\".AbsoluteYesCount"<<<"$gobject")
		YesCount=$(jq -r ".\"$hash\".YesCount"<<<"$gobject")
		NoCount=$(jq -r ".\"$hash\".NoCount"<<<"$gobject")
		AbstainCount=$(jq -r ".\"$hash\".AbstainCount"<<<"$gobject")
		fBlockchainValidity=$(jq -r ".\"$hash\".fBlockchainValidity"<<<"$gobject")
		IsValidReason=$(jq -r ".\"$hash\".IsValidReason"<<<"$gobject")
		fCachedValid=$(jq -r ".\"$hash\".fCachedValid"<<<"$gobject")
		fCachedFunding=$(jq -r ".\"$hash\".fCachedFunding"<<<"$gobject")
		fCachedDelete=$(jq -r ".\"$hash\".fCachedDelete"<<<"$gobject")
		fCachedEndorsed=$(jq -r ".\"$hash\".fCachedEndorsed"<<<"$gobject")
		DataString=$(jq -r ".\"$hash\".DataString"<<<"$gobject"|sed 's/\\"/"/g;s/"{/{/g')
		end_epoch=$(jq -r '.end_epoch'<<<"$DataString")
		name=$(jq -r '.name'<<<"$DataString")
		payment_address=$(jq -r '.payment_address'<<<"$DataString")
		payment_amount=$(jq -r '.payment_amount'<<<"$DataString")
		start_epoch=$(jq -r '.start_epoch'<<<"$DataString")
		Type=$(jq -r '.type'<<<"$DataString")
		url=$(jq -r '.url'<<<"$DataString")

		#echo "$ProposalHash $CollateralHash $ObjectType $CreationTime $AbsoluteYesCount $YesCount $NoCount $AbstainCount $fBlockchainValidity $IsValidReason $fCachedValid $fCachedFunding $fCachedDelete $fCachedEndorsed $end_epoch $name $payment_address $payment_amount $start_epoch $Type $url"
		if [[ "$CollateralHash" = "0000000000000000000000000000000000000000000000000000000000000000" ]];then continue;fi
		result=$(execute_sql "select count(1) from proposals where ProposalHash=\"$ProposalHash\";")
		if (( result==0 ));then
			# The proposal is not found, so add it.
			sql+="insert into proposals(run_date,ProposalHash,CollateralHash,ObjectType,CreationTime,fBlockchainValidity,IsValidReason,fCachedValid,fCachedFunding,fCachedDelete,fCachedEndorsed,end_epoch,name,payment_address,payment_amount,start_epoch,Type,url)values($run_date,\"$ProposalHash\",\"$CollateralHash\",$ObjectType,$CreationTime,\"$fBlockchainValidity\",\"$IsValidReason\",\"$fCachedValid\",\"$fCachedFunding\",\"$fCachedDelete\",\"$fCachedEndorsed\",$end_epoch,\"$name\",\"$payment_address\",\"$payment_amount\",$start_epoch,$Type,\"$url\");"
		else
			# The proposal exists, so just check if any of the data has changed make a log of it.
			{
				result=$(execute_sql "select count(1) from proposals where ProposalHash=\"$ProposalHash\" and CollateralHash=\"$CollateralHash\";")
				((result==0)) && echo "CollateralHash $CollateralHash changed for proposal $ProposalHash."
				result=$(execute_sql "select count(1) from proposals where ProposalHash=\"$ProposalHash\" and ObjectType=\"$ObjectType\";")
				((result==0)) && echo "ObjectType $ObjectType changed for proposal $ProposalHash."
				result=$(execute_sql "select count(1) from proposals where ProposalHash=\"$ProposalHash\" and CreationTime=\"$CreationTime\";")
				((result==0)) && echo "CreationTime $CreationTime changed for proposal $ProposalHash."
				result=$(execute_sql "select count(1) from proposals where ProposalHash=\"$ProposalHash\" and fBlockchainValidity=\"$fBlockchainValidity\";")
				((result==0)) && echo "fBlockchainValidity $fBlockchainValidity changed for proposal $ProposalHash."
				result=$(execute_sql "select count(1) from proposals where ProposalHash=\"$ProposalHash\" and IsValidReason=\"$IsValidReason\";")
				((result==0)) && echo "IsValidReason $IsValidReason changed for proposal $ProposalHash."
				result=$(execute_sql "select count(1) from proposals where ProposalHash=\"$ProposalHash\" and fCachedValid=\"$fCachedValid\";")
				((result==0)) && echo "fCachedValid $fCachedValid changed for proposal $ProposalHash."
				result=$(execute_sql "select count(1) from proposals where ProposalHash=\"$ProposalHash\" and fCachedFunding=\"$fCachedFunding\";")
				((result==0)) && echo "fCachedFunding $fCachedFunding changed for proposal $ProposalHash."
				result=$(execute_sql "select count(1) from proposals where ProposalHash=\"$ProposalHash\" and fCachedDelete=\"$fCachedDelete\";")
				((result==0)) && echo "fCachedDelete $fCachedDelete changed for proposal $ProposalHash."
				result=$(execute_sql "select count(1) from proposals where ProposalHash=\"$ProposalHash\" and fCachedEndorsed=\"$fCachedEndorsed\";")
				((result==0)) && echo "fCachedEndorsed $fCachedEndorsed changed for proposal $ProposalHash."
				result=$(execute_sql "select count(1) from proposals where ProposalHash=\"$ProposalHash\" and end_epoch=\"$end_epoch\";")
				((result==0)) && echo "end_epoch $end_epoch changed for proposal $ProposalHash."
				result=$(execute_sql "select count(1) from proposals where ProposalHash=\"$ProposalHash\" and name=\"$name\";")
				((result==0)) && echo "name $name changed for proposal $ProposalHash."
				result=$(execute_sql "select count(1) from proposals where ProposalHash=\"$ProposalHash\" and payment_address=\"$payment_address\";")
				((result==0)) && echo "payment_address $payment_address changed for proposal $ProposalHash."
				result=$(execute_sql "select count(1) from proposals where ProposalHash=\"$ProposalHash\" and payment_amount=\"$payment_amount\";")
				((result==0)) && echo "payment_amount $payment_amount changed for proposal $ProposalHash."
				result=$(execute_sql "select count(1) from proposals where ProposalHash=\"$ProposalHash\" and start_epoch=\"$start_epoch\";")
				((result==0)) && echo "start_epoch $start_epoch changed for proposal $ProposalHash."
				result=$(execute_sql "select count(1) from proposals where ProposalHash=\"$ProposalHash\" and Type=\"$Type\";")
				((result==0)) && echo "Type $Type changed for proposal $ProposalHash."
				result=$(execute_sql "select count(1) from proposals where ProposalHash=\"$ProposalHash\" and url=\"$url\";")
				((result==0)) && echo "url $url changed for proposal $ProposalHash."
			} >> "$DATADIR"/logs/warnings.log
		fi
		# Insert the votes.
		sql+="insert into votes(run_date,proposalhash,AbsoluteYesCount,YesCount,NoCount,AbstainCount)values($run_date,\"$ProposalHash\",$AbsoluteYesCount,$YesCount,$NoCount,$AbstainCount);"
	done
	# Insert the masternode data.
	sql+="insert into masternodes (run_date,height,collateralised_masternode_count,enabled_masternode_count)values($run_date,$height,$collateralised_masternode_count,$enabled_masternode_count);"
	sql+="commit;"
	echo "[$$] Running SQL / Inserting data..." >&2
	start_time=$EPOCHSECONDS
	execute_sql "$sql"
	echo "[$$] SQL took $((EPOCHSECONDS-start_time)) seconds to run." >&2
}

# Returns 0: Means the snapshot was held, the vote tallies had changed.
# Returns 1: Means the snapshot was purged, the vote tallies had not changed.
removeSnapShotIfNoChanges(){
	echo "[$$] Checking to see if the vote tallies have changed at all in this $run_date snapshot..." >&2
	# $votes is the number of historical snapshots we have in the database, since we are comparing the most recent with the one just before, we need to make sure the database has at least two snapshots of voting data otherwise the below is going to fail.
	((votes<1))&&return 1
	sql="select sum(diff_votes)from(select v1.run_date, v1.proposalhash,abs(v1.absoluteyescount-v2.absoluteyescount)as diff_votes from votes v1 join votes v2 on v1.proposalhash=v2.proposalhash where v1.run_date=(select max(run_date) from votes) and v2.run_date=(select max(run_date) from votes where run_date!=v1.run_Date));"
	sum_votes=$(execute_sql "$sql")
	# If the number of proposals is different between the snapshots, then keep the snapshot.  This deals with a new proposal arriving that doesn't get picked up because the join omits it.
	sql="select abs((select count(proposalhash)from votes where run_date=(select max(run_date) from votes))-(select count(proposalhash)from votes where run_date=(select run_date from(select distinct run_date,dense_rank()over(order by run_date desc)date_rank from votes)where date_rank=2)));"
	diff_proposals=$(execute "$sql")
	changes=$((sum_votes + diff_proposals))
	# If we sum the diffs between this snapshot and the previous one and get zero, then we know that the voting tallies have not changed and number of proposals have not changed and we may as well throw out that snapshot since it contains no new data.  ie the state is the same.
	if ((changes == 0));then
		echo "[$$] No changes found in the vote tallies, deleting snapshot $run_date..." >&2
		sql="begin transaction;delete from masternodes where run_date=$run_date;delete from votes where run_date=$run_date;commit;"
		execute_sql "$sql"
		return 1
	fi
}

signalMnowatch(){
	echo -n "[$$] Signaling MNOWatch...  Whale detected? " >&2
	sql="select max(diff_votes)from(select v1.run_date, v1.proposalhash,abs(v1.absoluteyescount-v2.absoluteyescount)as diff_votes from votes v1 join votes v2 on v1.proposalhash=v2.proposalhash where v1.run_date=(select max(run_date) from votes) and v2.run_date=(select max(run_date) from votes where run_date!=v1.run_Date));"
	biggest_change=$(execute_sql "$sql")
	((biggest_change >= 10)) && { echo "Yes!" >&2 ;mkdir -p /tmp/leaderboard;echo "https://mnowatch.org/leaderboard/analysis/?$run_date" >/tmp/leaderboard/found_whale_actions_run_mnowatch;}||echo "No." >&2
}

# Do it in two steps to the making the unlinking of the old file and the replacement of the new one instant.
copyToHtmlDir(){
	echo "[$$] Copying the database to /var/www/html/..." >&2
	cp -f "$DATABASE_FILE" /var/www/html/leaderboard/.proposals.db~
	mv -f /var/www/html/leaderboard/.proposals.db~ /var/www/html/leaderboard/.proposals.db
}

#################################################
#
#  Main
#
#################################################


check_dependencies
make_datadir
initialise_database
check_and_upgrade_database
parseAndLoadProposals
removeSnapShotIfNoChanges || exit 0
signalMnowatch
copyToHtmlDir
