#!/bin/sh

die() {
	local m="$1"
	echo "FATAL: $m" >&2
	exit 1
}

log() {
	local m="$1"
	echo
	echo "=== ${m}"
}

SCRIPTDIR="$(cd $(dirname "$0") && pwd)"
ORIGINAL_ARGS="$*"
REPO_CACHE="${SCRIPTDIR}/../cache/repo"
MASTER_URL=
MASTER_BRANCH=master
SLAVE_URL=
SLAVE_BRANCH=master
FORCE=
GERRIT_SSH_HOST=git-sync@localhost
GERRIT_SSH_PORT=29418

usage() {
	cat << __EOF__
Usage: $0 [OPTIONS]
Syncrhonize master/slave git.

    --repo-cache=PATH             location of git repo used for cache [./cache/repo]
    --master-url=URL              remote of master repo.
    --master-branch=BRANCH        master repo branch to use. [${MASTER_BRANCH}]
    --slave-url=URL               remote of slave repo.
    --slave-branch=BRANCH         slave repo branch to use. [${SLAVE_BRANCH}]
    --gerrit-ssh-host=user@host   gerrit ssh host, required for force. [${GERRIT_SSH_HOST}]
    --gerrit-ssh-port=PORT        gerrit ssh port, required for force. [${GERRIT_SSH_PORT}]
    --force                       slave repo push.
__EOF__
}

while [ -n "$1" ]; do
	x="$1"
	v="${x#*=}"
	shift
	case "${x}" in
		--repo-cache=*)
			REPO_CACHE="${v}"
		;;
		--master-url=*)
			MASTER_URL="${v}"
		;;
		--master-branch=*)
			MASTER_BRANCH="${v}"
		;;
		--slave-url=*)
			SLAVE_URL="${v}"
		;;
		--slave-branch=*)
			SLAVE_BRANCH="${v}"
		;;
		--gerrit-ssh-host=*)
			GERRIT_SSH_HOST="${v}"
		;;
		--gerrit-ssh-port=*)
			GERRIT_SSH_PORT="${v}"
		;;
		--force)
			FORCE=1
		;;
		--help)
			usage
			exit 0
		;;
		*)
			usage
			exit 1
		;;
	esac
done

[ -n "${MASTER_URL}" ] || die "Please specify master repository location"
[ -n "${SLAVE_URL}" ] || die "Please specify slave repository location"
if [ -n "${FORCE}" ]; then
	[ -n "${GERRIT_SSH_HOST}" ] || die "Please specify gerrit ssh host"
fi

log "Syncing '${MASTER_URL}/${MASTER_BRANCH}' -> '${SLAVE_URL}/${SLAVE_BRANCH}'"

if [ -d "${REPO_CACHE}" ]; then
	cd "${REPO_CACHE}" || die "no repo '${REPO_CACHE}'"
else
	log "Creating repository"
	mkdir -p "${REPO_CACHE}" || die "failed to create '${REPO_CACHE}'"
	git init . || die "git init failed"
	git commit -m "root commit" --allow-empty
fi

log "Cleanup repository"
git clean -dxf || die "clean"
git reset --hard || die "reset"
git rebase --abort 2> /dev/null
git cherry-pick --abort 2> /dev/null
git checkout master || die "master"
git clean -dxf || die "clean"
git branch -D sync 2> /dev/null

log "Fetching slave repo"
git fetch "${SLAVE_URL}" "${SLAVE_BRANCH}" || die "fetch '${SLAVE_URL}'"
git checkout -b sync FETCH_HEAD || die "checkout FETCH_HEAD"

if [ -n "${FORCE}" ]; then
	BACKUP="slave-$(date -u +"%Y%m%d%H%M%S")-$(git rev-parse --short HEAD)"
	log "Backing up slave repo to '${BACKUP}'"
	git branch "${BACKUP}" || die "backup failed"
fi

log "Fetching master repo"
git fetch "${MASTER_URL}" "${MASTER_BRANCH}" || die "fetch '${MASTER_URL}'"

log "Rebasing slave on top of master"
if ! git rebase FETCH_HEAD; then
	git rebase --abort
	echo
	echo "Probably there are commits at same time in both master and slave"
	echo "Unfortunatally the slave changes conflict with the master changes"
	echo "This issue should be resolved manually"
	die "rebase '${MASTER_URL}/${MASTER_BRANCH}' failed"
fi

if [ -n "${FORCE}" ]; then
	log "FORCE MODE"
	log "Suspending merges"
	ssh -p "${GERRIT_SSH_PORT}" "${GERRIT_SSH_HOST}" merge-suspend merge-suspend || die "Cannot suspend merges"
	log "Pusing slave with force"
	git push --force "${SLAVE_URL}" "sync:${SLAVE_BRANCH}"
	res=$?
	log "Resuming merges"
	ssh -p "${GERRIT_SSH_PORT}" "${GERRIT_SSH_HOST}" merge-suspend merge-resume || die "Cannot resume merges"
	[ "${res}" = 0 ] || die "Cannot push changes into slave '${SLAVE_URL}/${SLAVE_BRANCH}'"
else
	log "Pusing slave"
	if ! git push "${SLAVE_URL}" "sync:${SLAVE_BRANCH}"; then
		echo
		echo "Probably there are commits at same time in both master and slave"
		echo "Running manually git-sync with --force may resolve the issue."
		echo "${SCRIPTDIR}/git-sync.sh ${ORIGINAL_ARGS} --force --gerrit-ssh-host=${GERRIT_SSH_HOST} --gerrit-ssh-port=${GERRIT_SSH_PORT}"
		die "Cannot push changes into slave '${SLAVE_URL}/${SLAVE_BRANCH}'"
	fi
fi

log "Pusing master"
if ! git push "${MASTER_URL}" "sync:${MASTER_BRANCH}"; then
	echo
	echo "Probably there was a commit in master at time we tried to sync"
	echo "Running git-sync again should resolve the issue."
	die "push '${MASTER_URL}/${MASTER_BRANCH}'"
fi

git checkout master
