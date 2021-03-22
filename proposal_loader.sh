#!/bin/bash
#set -x

VERSION="$0 (v0.2.3 build date 202103221400)"
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
	sql+="create table votes(run_date integer not null check(run_date>=0),height integer not null check(height>=0), ProposalHash text not null,  AbsoluteYesCount integer not null, YesCount integer not null, NoCount integer not null, AbstainCount integer not null,foreign key(ProposalHash)references proposals(ProposalHash), primary key(run_date,ProposalHash));"
	sql+="create index idx_vote_ProposalHash on votes(ProposalHash);"
	sql+="create trigger delete_proposal before delete on proposals for each row begin delete from votes where ProposalHash=old.ProposalHash;delete from votes where ProposalHash=old.ProposalHash;end;"
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
		sql+="insert into votes(run_date,height,proposalhash,AbsoluteYesCount,YesCount,NoCount,AbstainCount)values($run_date,$height,\"$ProposalHash\",$AbsoluteYesCount,$YesCount,$NoCount,$AbstainCount);"
	done
	sql+="commit;"
	echo "[$$] Running SQL / Inserting data..." >&2
	start_time=$EPOCHSECONDS
	execute_sql "$sql"
	echo "[$$] SQL took $((EPOCHSECONDS-start_time)) seconds to run." >&2
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

