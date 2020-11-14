# proposal_loader
Creates a SQLite database of DASH Proposals


This will parse the DASH Governance objects and write the data (all of it) into a SQLite database for easy querying.  Run it in a loop to add to the DB and create a historical record. It does not capture the ID's of the masternodes that vote, but rather the tallies of each proposal, this will be the database used to create a new DASH proposal leaderboard.
