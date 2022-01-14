#!/bin/bash
#set -x

VERSION="$0 (v0.7.0 build date 202201140000)"
DATABASE_VERSION=3
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


dcli () {
	dash-cli -datadir=/tmp -conf=/etc/dash.conf "$@" || { echo "dash-cli error, exiting...";exit 1;}
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
	which dash-cli >/dev/null 2>&1 || { echo "dash-cli is not in PATH, please ensure a working dashd is present and in PATH.";exit 1;}
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
	sql+="insert into db_version values($DATABASE_VERSION);"
	sql+="create table proposals(run_date integer not null check(run_date>=0), ProposalHash text primary key not null, CollateralHash text not null, ObjectType integer not null, CreationTime integer not null, fBlockchainValidity text not null, IsValidReason text, fCachedValid text not null, fCachedFunding text not null, fCachedDelete text not null, fCachedEndorsed text not null, end_epoch integer not null, name text nor null, payment_address text not null, payment_amount real not null check(payment_amount>=0), start_epoch integer not null, Type integer not null, url text);"
	sql+="create unique index idx_ProposalHash on proposals(ProposalHash);"
	sql+="create table votes(run_date integer not null check(run_date>=0),ProposalHash text not null,AbsoluteYesCount integer not null, YesCount integer not null, NoCount integer not null, AbstainCount integer not null,foreign key(ProposalHash)references proposals(ProposalHash), primary key(run_date,ProposalHash));"
	sql+="create table proposal_owners(run_date integer not null,ProposalHash text primary key not null,ProposalOwner text,foreign key(ProposalHash)references proposals(ProposalHash));"
	# If this table is new, pre-load it with
	# insert into proposal_owners (proposalhash,run_date) select distinct proposalhash,(select max(run_date) from votes) from proposals;
	sql+="create index idx_vote_ProposalHash on votes(ProposalHash);"
	sql+="create table masternodes (run_date integer primary key not null check(run_date>=0), height integer not null check(height>=0), collateralised_masternode_count integer not null check(collateralised_masternode_count>=0),enabled_masternode_count integer not null check(enabled_masternode_count>=0));"
	sql+="create index idx_masternode_rundate on masternodes(run_date);"
	sql+="create trigger delete_proposal before delete on proposals for each row begin delete from votes where ProposalHash=old.ProposalHash;end;"
	# The superblock column stores the height at which the superblock happened, the dash_price will be the price of the coin at the time the block occured.
	sql+="create table superblocks(run_date integer not null, superblock_date integer not null,superblock integer not null primary key, dash_price real not null);"
	sql+="create table map_proposals_superblocks(ProposalHash text not null, superblock integer not null, primary key(ProposalHash,superblock), foreign key(ProposalHash)references proposals(ProposalHash), foreign key(superblock)references superblocks(superblock));"

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
	height=$(dcli getblockcount)|| { echo "dash-cli failed, exiting...";exit 1;}
	masternode=$(dcli masternode count)
	collateralised_masternode_count=$(jq -r '.total'<<<"$masternode")
	enabled_masternode_count=$(jq -r '.enabled'<<<"$masternode")

	gobject=$(dcli gobject list)
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
	((votes<1))&&return 0
	sql="select sum(diff_votes)from(select v1.run_date, v1.proposalhash,abs(v1.absoluteyescount-v2.absoluteyescount)as diff_votes from votes v1 join votes v2 on v1.proposalhash=v2.proposalhash where v1.run_date=(select max(run_date) from votes) and v2.run_date=(select max(run_date) from votes where run_date!=v1.run_Date));"
	sum_votes=$(execute_sql "$sql")
	# If the number of proposals is different between the snapshots, then keep the snapshot.  This deals with a new proposal arriving that doesn't get picked up because the join omits it.
	sql="select abs((select count(proposalhash)from votes where run_date=(select max(run_date) from votes))-(select count(proposalhash)from votes where run_date=(select run_date from(select distinct run_date,dense_rank()over(order by run_date desc)date_rank from votes)where date_rank=2)));"
	diff_proposals=$(execute_sql "$sql")
	changes=$((sum_votes + diff_proposals))
	# If we sum the diffs between this snapshot and the previous one and get zero, then we know that the voting tallies have not changed and number of proposals have not changed and we may as well throw out that snapshot since it contains no new data.  ie the state is the same.
	if ((changes == 0));then
		echo "[$$] No changes found in the vote tallies, deleting snapshot $run_date..." >&2
		sql="begin transaction;delete from masternodes where run_date=$run_date;delete from votes where run_date=$run_date;commit;"
		execute_sql "$sql"
		return 1
	fi
}

loadProposalOwners(){
	echo "[$$] Finding any new proposal owners and loading them into the database..." >&2
	# We assume that this $run_date is in the database.
	sql="select distinct proposalhash from votes where run_date=$run_date;"
	proposalhashes=$(execute_sql "$sql")
	for hash in $proposalhashes;do
		#echo "$hash"
		isFound=$(execute_sql "select \"yes\" from proposal_owners where proposalhash=\"$hash\";")
		if [[ "$isFound" != "yes" ]];then
			echo "[$$] No record in Proposal_Owners table for proposal_hash $hash, inserting now..." >&2
			execute_sql "insert into proposal_owners values($run_date,\"$hash\",\"\");"
		fi
		proposalowner=$(execute_sql "select proposalowner from proposal_owners where proposalhash=\"$hash\";")
		#echo "proposalowner = #${proposalowner}#"
		if [[ "$proposalowner" == "" ]];then
			echo "[$$] Found missing proposal owner that needs updating for proposal_hash $hash..." >&2
			proposalowner=$(curl -s https://www.dashcentral.org/api/v1/proposal?hash=$hash|jq -r .proposal.owner_username)
			retValCombined=$(($? + PIPSTATUS))
			if ((retValCombined == 0)) && [[ $proposalowner != "null" ]] ;then
				echo "[$$] Updating missing proposal owner '$proposalowner' in the database for proposal_hash $hash..." >&2
				execute_sql "update proposal_owners set proposalowner=\"$proposalowner\" where proposalhash=\"$hash\";"
			fi
		fi
	done
}


loadSuperBlockData(){
	(($# != 1)) && return
	superblock=$1
	echo "[$$] Found a new Superblock at height $superblock, loading..." >&2

	# Superblock table requires the superblock height, we have it, the date, we can get it and the price at that date.

	block_hash=$(dcli getblockhash $superblock)
	block=$(dcli getblock "$block_hash")
	block_time_seconds=$(jq -r '.time'<<<"$block")
	block_time=$(date +"%Y%m%d%H%M%S" -d @$block_time_seconds)
	block_date=$(date +"%d-%m-%Y" -d @$block_time_seconds)
	price=$(curl -s -X 'GET' "https://api.coingecko.com/api/v3/coins/dash/history?date=${block_date}&localization=en" -H 'accept: application/json'|jq '.market_data.current_price.usd')
	[[ -z $price ]] && return 1
	# Test for a valid number.
	regex="^[-+]?[0-9]+\.?[0-9]*$"
	[[ $price =~ $regex ]] || return 2
	price=$(printf '%0.2f' $price)
	echo "[$$] Determined price of Dash on $block_date was \$$price." >&2
	sql="insert into superblocks (run_date, superblock_date, superblock, dash_price)values($run_date, $block_time, $superblock, \"$price\");"
	execute_sql "$sql"

	# The next step is to get a list of coinbase transactions and build an arrary of key=value pairs where the key is the payout address and the value is the Dash paid to it.

	# Here I assume the first TX is the coinbase, but we still check for it in case it is not.
	tx_hash=$(jq -r .tx[0] <<<"$block")
	tx=$(dcli getrawtransaction $tx_hash 1)
	coinbase=$(jq -r '.vin[].coinbase' <<< "$tx"|head -1)
	[[ $coinbase == "null" ]] && { echo "[$$] Error! This transaction $tx_hash in block $superblock is not a coinbase!";return 3;}

	# If we got this far, the TX is a coinbase and we can extract what we need.
	declare -A address_array
	num_addresses=$(jq -r '.vout|length'<<< "$tx")
	for((i=0;i<num_addresses;i++));do
		address=$(jq -r ".vout[$i].scriptPubKey.addresses"<<< "$tx"|sed -n 2p|sed 's/.*"\(.*\)"/\1/')
		value=$(jq -r ".vout[$i].value"<<< "$tx")
		if [[ -z ${address_array[$address]} ]];then
			address_array[$address]=$value
		else
			echo "[$$] Duplicate payment found in tx hash $tx_hash ($address for $value Dash)." >&2
			address_array[$address]+=" $value"
		fi
	done



	# The next step is to determine the proposals active just before the voting closed and match those to payout transactions in the superblock.
	# Voting will close this number of blocks before the superblock.
	voting_deadline=$((superblock - 1662))
	sql="select max(run_date) from masternodes where height=(select max(height) from masternodes where height<=$voting_deadline);"
	best_run_date=$(execute_sql "$sql")
	# Get the proposals with votes on that run_date.
	sql="select p.proposalhash ,payment_address,payment_amount from votes v join proposals p on p.ProposalHash=v.ProposalHash where v.run_date=$best_run_date order by AbsoluteYesCount desc;"
	while IFS="|" read proposalhash payment_address payment_amount junk;do
		Value=${address_array[$payment_address]}
		# Deal with the duplicates
		num_dups=$(awk '{print NF}'<<<"$Value")
		((num_dups == 0))&&echo "[$$] Proposal $proposalhash to address $payment_address for $payment_amount Dash was not paid."
		for((k=1;k<num_dups+1;k++));do
			value=$(awk -v k=$k '{print $k}'<<<"$Value")
			#echo "[$$] payment_address = $payment_address value=$value payment_amount=$payment_amount"
			# Standardise the amounts, for some reason, the database has cases with more than 8 decimals.
			payment_amount=$(printf '%.8f' $payment_amount)
			retval=$(bc<<<"$value == $payment_amount")
			if ((retval == 1));then
				# This bit prevents trying to insert the same proposal twice eg in the case the same address was paid the same amount two or more times in the block, eg
				# https://chainz.cryptoid.info/dash/tx.dws?7a9b10f7ea616827ef69b52ada3c734e25c7de40fe3b3c18e2ee6739ae78e191.htm
				retval=$(execute_sql "select 1 from map_proposals_superblocks where proposalhash=\"$proposalhash\" and superblock=$superblock;")
				if [[ -z $retval ]];then
					# We have found a match, so store this to the database.
					echo "[$$] Matched payment for proposal $proposalhash paying to $payment_address for the amount of $payment_amount Dash. Loading database..." >&2
					execute_sql "insert into map_proposals_superblocks values(\"$proposalhash\",$superblock);"
				fi
			fi
		done
	done < <(execute_sql "$sql")
}


# This function will insert rows into the following two tables:
# superblocks
# map_proposals_superblocks

determineSuperBlock(){
	# 1. Check for the heightest superblock number recorded in superblocks, if null set it as zero.
	# 2. Check on heightest block number in masternodes and the lowest, if null, set to zero.
	# 3. Return it max or min of masternodes block is zero.
	# 4. Subtract height mn block from max of superblock and lowest block from masternodes.
	# 5. Check for a superblock in this range.  If found determine its properties and continue with others.

	echo "[$$] Determining if a superblock has passed that needs data to be loaded into the database..." >&2

	max_height=$(execute_sql "select max(height) from masternodes;")
	[[ -z $max_height ]] && return

	min_height=$(execute_sql "select min(height) from masternodes;")

	max_superblock=$(execute_sql "select max(superblock) from superblocks;")
	[[ -z $max_superblock ]] && max_superblock=0

	if ((max_superblock <= min_height));then
		start_height=$min_height
	else
		start_height=$max_superblock
	fi

	# Now from start_height to max_height, determine if a superblock occured in that range.
	# This variable is a superblock in the distant past.
	SUPERBLOCK=980344
	SUPERBLOCK_INTERVAL=16616

	for((; SUPERBLOCK < max_height; SUPERBLOCK += SUPERBLOCK_INTERVAL));do
		((SUPERBLOCK < start_height)) && continue
		# If we get here, then this block must be a superblock in the range we are looking for, so populate the data.
		loadSuperBlockData $SUPERBLOCK || break
	done

}

signalMnowatch(){
	echo -n "[$$] Signaling MNOWatch...  Whale detected? " >&2
	sql="select max(diff_votes)from(select v1.run_date, v1.proposalhash,abs(v1.absoluteyescount-v2.absoluteyescount)as diff_votes from votes v1 join votes v2 on v1.proposalhash=v2.proposalhash where v1.run_date=(select max(run_date) from votes) and v2.run_date=(select max(run_date) from votes where run_date!=v1.run_Date));"
	biggest_change=$(execute_sql "$sql")
	((biggest_change >= 20)) && { echo "Yes!" >&2 ;mkdir -p /tmp/leaderboard;echo "https://mnowatch.org/leaderboard/analysis/?$run_date" >/tmp/leaderboard/found_whale_actions_run_mnowatch;}||echo "No." >&2
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
parseAndLoadProposals || exit 1
removeSnapShotIfNoChanges || exit 0
loadProposalOwners
determineSuperBlock
#signalMnowatch
#copyToHtmlDir

