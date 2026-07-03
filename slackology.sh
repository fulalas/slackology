#!/bin/bash

set -uo pipefail

scriptDir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
fileListUrl="http://ftp.slackware.com/pub/slackware/slackware64-current/slackware64/FILE_LIST"
packagesFile=""
apiBase="https://repology.org/api/v1/project"
userAgent="slackology/1.0 (+https://repology.org/api; personal use script)"
jobs=""
apiConcurrency="3"
delay=""
cacheDir="$HOME/.cache/slackology"
cacheEntriesDir="$cacheDir/entries"
cacheTtl=$((24 * 3600))
useCache=true
clearCache=false
buildEnabled=false
onlyPackages=()
installedOnly=false
pkgDbDir="/var/log/packages"
sourceDir="$scriptDir/source"
upstreamFile=""
upstreamFileSet=false
repologyMapFile=""
repologyMapSet=false

reset=$'\033[0m'
bold=$'\033[1m'
cyan=$'\033[0;36m'
green=$'\033[0;32m'
red=$'\033[0;31m'
yellow=$'\033[0;33m'
brown=$'\033[1;33m'

tagWidth=12

printHelp() {
	local cacheTtlHours=$((cacheTtl / 3600))
	cat <<EOF
Usage: $(basename "$0") [options]

Downloads a Slackware repository FILE_LIST and compares each package's
packaged version against its upstream project's latest known version via
the Repology aggregator (https://repology.org). Every package in the
listing is checked -- there's no dependency on what's installed locally.

The FILE_LIST itself is never cached; it's downloaded fresh on every run
(or read straight from -f/--file). What IS cached is each package's
Repology lookup result, for ${cacheTtlHours}h, under:
  $cacheDir

Pass -b/--build to, for each outdated package, fetch its latest upstream
source (via its upstreamLinks.tsv URL) into the package's local SlackBuild
directory in the source tree (a source/ folder laid out like
source/<category>/<pkg>/), then run its <pkg>.SlackBuild to build it. The
fetch method is chosen from the URL (git forge -> newest release tag; PyPI/
RubyGems -> sdist/gem; SourceForge -> newest release; plain http/ftp dir ->
newest tarball). Off by default.

Pass -i/--installed to check only the packages actually installed on this
machine, read from $pkgDbDir, instead of the FILE_LIST universe
(-u/-f are ignored in this mode).

The --build fetch step reads each package's upstream source location from
a TSV file (columns: package<TAB>upstream_url). If a file named
upstreamLinks.tsv sits next to this script it is used automatically;
override with -U/--upstream-file, disable with -U ''.

Package names are translated to Repology's project names before querying.
Case and _/- differences are normalized automatically, so the map file
(lines: "slackware_name repology_name") only needs genuine renames -- e.g.
Slackware's mozilla-firefox is Repology's firefox. If a file named
repologyNames.map sits next to this script it is used automatically;
override with -R/--repology-map, disable with -R '' (normalization still
applies). Names with no map entry are queried in normalized form.

Options:
  -u, --url URL              FILE_LIST URL to parse for the package universe
                             (default: $fileListUrl)
  -f, --file PATH            Use a local repo listing instead of downloading
  -i, --installed            Check only packages installed on this machine
                             (reads $pkgDbDir, ignores -u/-f)
  -s, --source-dir DIR       Local Slackware source tree used by --build
                             (default: $sourceDir)
  -p, --package NAME         Check only this package (repeatable)
  -j, --jobs N               Parallel workers (default: number of CPU cores)
  -r, --parallel-requests N  Concurrent live API requests allowed (default: $apiConcurrency)
  -d, --delay SECONDS        Minimum spacing between live API calls within
                             the same request slot (default: 1.1)
  -n, --no-cache             Ignore cached Repology lookups (normally kept
                             for ${cacheTtlHours}h) and re-query every package
  -b, --build                Fetch latest source + build each outdated
                             package from its local SlackBuild (see -s)
  -U, --upstream-file PATH   TSV of package<TAB>upstream_url used by --build
                             to fetch sources (default: auto-detect
                             upstreamLinks.tsv beside the script; '' disables)
  -R, --repology-map PATH    Map of "slackware_name repology_name" used to
                             translate names before the Repology query
                             (default: auto-detect repologyNames.map; '' off)
  -c, --clear-cache          Delete all cached Repology lookups, then run
  -h, --help                 Show this help
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
	-u | --url)
		fileListUrl="$2"
		shift 2
		;;
	-f | --file)
		packagesFile="$2"
		shift 2
		;;
	-i | --installed)
		installedOnly=true
		shift
		;;
	-s | --source-dir)
		sourceDir="$2"
		shift 2
		;;
	-p | --package)
		onlyPackages+=("$2")
		shift 2
		;;
	-j | --jobs)
		jobs="$2"
		shift 2
		;;
	-r | --parallel-requests)
		apiConcurrency="$2"
		shift 2
		;;
	-d | --delay)
		delay="$2"
		shift 2
		;;
	-n | --no-cache)
		useCache=false
		shift
		;;
	-b | --build)
		buildEnabled=true
		shift
		;;
	-U | --upstream-file)
		upstreamFile="$2"
		upstreamFileSet=true
		shift 2
		;;
	-R | --repology-map)
		repologyMapFile="$2"
		repologyMapSet=true
		shift 2
		;;
	-c | --clear-cache)
		clearCache=true
		shift
		;;
	-h | --help)
		printHelp
		exit 0
		;;
	*)
		echo "Unknown option: $1" >&2
		exit 1
		;;
	esac
done

for bin in curl jq xargs nproc flock; do
	if ! command -v "$bin" >/dev/null 2>&1; then
		echo "Error: '$bin' is required but not installed." >&2
		exit 1
	fi
done

if [ -z "$jobs" ]; then
	jobs=$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)
fi
if [ -z "$delay" ]; then
	delay="1.1"
fi

if ! [[ "$apiConcurrency" =~ ^[1-9][0-9]*$ ]]; then
	echo "Error: -r/--parallel-requests must be a positive integer." >&2
	exit 1
fi
if ! [[ "$jobs" =~ ^[1-9][0-9]*$ ]]; then
	echo "Error: -j/--jobs must be a positive integer." >&2
	exit 1
fi

if [ "$upstreamFileSet" = false ] && [ -f "$scriptDir/upstreamLinks.tsv" ]; then
	upstreamFile="$scriptDir/upstreamLinks.tsv"
fi
if [ -n "$upstreamFile" ] && [ ! -f "$upstreamFile" ]; then
	echo "Error: upstream file not found: $upstreamFile" >&2
	exit 1
fi

if [ "$repologyMapSet" = false ] && [ -f "$scriptDir/repologyNames.map" ]; then
	repologyMapFile="$scriptDir/repologyNames.map"
fi
if [ -n "$repologyMapFile" ] && [ ! -f "$repologyMapFile" ]; then
	echo "Error: repology map not found: $repologyMapFile" >&2
	exit 1
fi

declare -A repologyNameMap
if [ -n "$repologyMapFile" ] && [ -f "$repologyMapFile" ]; then
	while read -r mapKey mapValue; do
		[ -n "$mapKey" ] && [ -n "$mapValue" ] || continue
		mapKey="${mapKey,,}"
		repologyNameMap["${mapKey//_/-}"]="$mapValue"
	done <"$repologyMapFile"
fi

resultsDir=$(mktemp -d)
trap 'rm -rf "$resultsDir"' EXIT
buildQueueDir="$resultsDir/build-queue"
mkdir -p "$buildQueueDir"

repoNames=()
declare -A repoNamesSeen
declare -A repoVersion

addPackage() {
	local full="$1" nameVersion name version
	nameVersion="${full%-*}"
	nameVersion="${nameVersion%-*}"
	name="${nameVersion%-*}"
	if [ "$name" = "$nameVersion" ]; then
		version=""
	else
		version="${nameVersion##*-}"
	fi
	if [ -z "${repoNamesSeen[$name]:-}" ]; then
		repoNamesSeen[$name]=1
		repoVersion[$name]="$version"
		repoNames+=("$name")
	fi
}

if [ "$installedOnly" = true ]; then
	if [ ! -d "$pkgDbDir" ]; then
		echo "Error: package database directory not found: $pkgDbDir" >&2
		exit 1
	fi

	for pkgFile in "$pkgDbDir"/*; do
		[ -f "$pkgFile" ] || continue
		addPackage "${pkgFile##*/}"
	done

	if [ ${#repoNames[@]} -eq 0 ]; then
		echo "Error: no installed packages found in $pkgDbDir" >&2
		exit 1
	fi
else
	if [ -z "$packagesFile" ]; then
		packagesFile="$resultsDir/FILE_LIST"
		echo "Fetching repo listing from $fileListUrl..."
		if ! curl -fsSL --max-time 60 -A "$userAgent" "$fileListUrl" -o "$packagesFile"; then
			echo "Error: failed to download $fileListUrl" >&2
			exit 1
		fi
	elif [ ! -f "$packagesFile" ]; then
		echo "Error: repo listing not found: $packagesFile" >&2
		exit 1
	fi

	while IFS= read -r line; do
		if [[ $line == -* && $line == *.txz ]]; then
			tmp="${line#*.}"
			tmp="${tmp%.*}"
			addPackage "${tmp##*/}"
		fi
	done <"$packagesFile"

	if [ ${#repoNames[@]} -eq 0 ]; then
		echo "Error: no *.txz entries found in $packagesFile -- is it a valid repo listing?" >&2
		exit 1
	fi
fi

if [ "$clearCache" = true ]; then
	rm -rf "$cacheDir"
	echo "Cache cleared."
fi
mkdir -p "$cacheEntriesDir"

if [ ${#onlyPackages[@]} -gt 0 ]; then
	filtered=()
	for want in "${onlyPackages[@]}"; do
		[ -n "${repoNamesSeen[$want]:-}" ] && filtered+=("$want")
	done
	repoNames=("${filtered[@]}")
fi

toProcess=()
for pkgName in "${repoNames[@]}"; do
	normName="${pkgName,,}"
	normName="${normName//_/-}"
	toProcess+=("${pkgName}@${repoVersion[$pkgName]}@${repologyNameMap[$normName]:-$normName}")
done

total=${#repoNames[@]}
runStartTs=$(date +%s)

echo -e "${bold}${cyan}Upstream package version checker${reset}"
if [ "$installedOnly" = true ]; then
	echo -e "Package source: installed packages in $pkgDbDir ($total unique packages)"
else
	echo -e "Repo listing:   $packagesFile ($total unique packages)"
fi
echo -e "Upstream data source: https://repology.org (API)"
if [ -n "$upstreamFile" ]; then
	echo -e "Upstream links: $upstreamFile"
fi
if [ -n "$repologyMapFile" ]; then
	echo -e "Repology name map: $repologyMapFile"
fi
echo -e "Workers: $jobs parallel ($apiConcurrency concurrent API requests, min ${delay}s apart per slot)"
if [ "$buildEnabled" = true ]; then
	echo -e "Build: enabled (--build) -- will fetch latest source into $sourceDir and build outdated packages\n"
else
	echo -e "Build: disabled (pass --build to enable)\n"
fi

hashSlot() {
	local __resultVar="$1" s="$2" sum=0 i c
	for ((i = 0; i < ${#s}; i++)); do
		printf -v c '%d' "'${s:i:1}"
		sum=$(((sum * 31 + c) % 1000003))
	done
	printf -v "$__resultVar" '%d' "$sum"
}

acquireSlotLock() {
	local poolPrefix="$1" key="$2" concurrency="$3"
	local h slot
	hashSlot h "$key"
	slot=$((h % concurrency))
	exec 200>"$cacheDir/${poolPrefix}-lock-$slot"
	flock -x 200
}

releaseSlotLock() {
	exec 200>&-
}

printStatus() {
	local color="$1" tagText="$2" message="$3"
	local tag
	printf -v tag '%-*s' "$tagWidth" "[$tagText]"
	echo -e "  ${color}${tag}${reset} ${message}"
}

lookupUpstream() {
	local pkg="$1"
	[ -n "$upstreamFile" ] && [ -f "$upstreamFile" ] || return 0
	awk -F'\t' -v p="$pkg" '$1 == p { print $2; exit }' "$upstreamFile"
}

export -f hashSlot acquireSlotLock releaseSlotLock printStatus lookupUpstream
export cacheDir tagWidth reset upstreamFile

buildPackage() {
	local token="$1" pkg repoVersion newest url
	IFS=$'\t' read -r pkg repoVersion newest url <<<"$token"

	local sb=""
	local -a matches=("$sourceDir"/*/"$pkg"/"$pkg.SlackBuild")
	if [ -e "${matches[0]}" ]; then
		sb="${matches[0]}"
	else
		sb=$(find "$sourceDir" -type f -name "$pkg.SlackBuild" 2>/dev/null | head -n1)
	fi
	if [ -z "$sb" ]; then
		printStatus "$yellow" build "$pkg: no $pkg.SlackBuild found under $sourceDir"
		return 1
	fi
	local dir="${sb%/*}"

	local how
	if [ -n "$url" ]; then
		if how=$(fetchInto "$url" "$dir"); then
			printStatus "$green" fetch "$pkg: fetched latest source via $how -> $dir"
		else
			printStatus "$yellow" fetch "$pkg: could not fetch $url (building with existing sources)"
		fi
	else
		printStatus "$yellow" fetch "$pkg: no upstream link on file (building with existing sources)"
	fi

	printStatus "$cyan" build "$pkg: building $repoVersion -> $newest ($sb)"
	( cd "$dir" && bash "./$pkg.SlackBuild" )
	local rc=$?
	if [ "$rc" -eq 0 ]; then
		printStatus "$green" build "$pkg: build succeeded"
	else
		printStatus "$red" build "$pkg: build FAILED (exit $rc)"
	fi
	return "$rc"
}

gitForgeRe='(github|gitlab|codeberg|invent\.kde|salsa|code\.videolan|gitweb|lovelyhq|forge\.slackware|adelielinux)|(^|\.)sr\.ht$|(^git\.)'
preReleaseRe='alpha|beta|rc[0-9]|-pre|snapshot'

fetchGit() {
	local url="$1" dest="$2"
	url="${url%/}"
	url="${url%.git}"
	local tag
	tag=$(GIT_TERMINAL_PROMPT=0 timeout 60 git ls-remote --tags --refs "$url" 2>/dev/null |
		awk '{print $2}' | sed 's#refs/tags/##' |
		grep -viE "$preReleaseRe" | grep -E '^[vV]?[0-9]' |
		awk '{ key = $0; sub(/^[vV]/, "", key); print key "\t" $0 }' |
		sort -V | tail -n1 | cut -f2-)
	if [ -n "$tag" ] &&
		GIT_TERMINAL_PROMPT=0 timeout 600 git clone --quiet --depth 1 --branch "$tag" "$url" "$dest" >/dev/null 2>&1; then
		echo "git tag $tag"
		return 0
	fi
	if GIT_TERMINAL_PROMPT=0 timeout 600 git clone --quiet --depth 1 "$url" "$dest" >/dev/null 2>&1; then
		echo "git default branch"
		return 0
	fi
	return 1
}

fetchTarball() {
	local fileUrl="$1" dest="$2" name="${3:-}"
	if [ -z "$name" ]; then
		name="${fileUrl##*/}"
		name="${name%%\?*}"
	fi
	[ -n "$name" ] || name="download"
	if curl -fsSL --max-time 600 -A "$userAgent" -o "$dest/$name" "$fileUrl" 2>/dev/null; then
		echo "$name"
		return 0
	fi
	return 1
}

urlBasename() {
	local b="${1%/}"
	REPLY="${b##*/}"
}

fetchPypi() {
	local url="$1" dest="$2" name sdist
	urlBasename "$url"
	name="$REPLY"
	sdist=$(curl -fsSL --max-time 30 -A "$userAgent" "https://pypi.org/pypi/$name/json" 2>/dev/null |
		jq -r '.urls[]? | select(.packagetype=="sdist") | .url' 2>/dev/null | head -n1)
	[ -n "$sdist" ] || return 1
	fetchTarball "$sdist" "$dest"
}

fetchGem() {
	local url="$1" dest="$2" name gemUrl
	urlBasename "$url"
	name="$REPLY"
	gemUrl=$(curl -fsSL --max-time 30 -A "$userAgent" "https://rubygems.org/api/v1/gems/$name.json" 2>/dev/null |
		jq -r '.gem_uri // empty' 2>/dev/null)
	[ -n "$gemUrl" ] || return 1
	fetchTarball "$gemUrl" "$dest"
}

fetchSourceForge() {
	local url="$1" dest="$2" proj file
	proj=$(printf '%s' "$url" | sed -E 's#.*/projects/([^/]+).*#\1#')
	[ -n "$proj" ] || return 1
	file=$(curl -fsSL --max-time 30 -A "$userAgent" "https://sourceforge.net/projects/$proj/best_release.json" 2>/dev/null |
		jq -r '.release.filename // empty' 2>/dev/null)
	[ -n "$file" ] || return 1
	fetchTarball "https://sourceforge.net/projects/$proj/files$file/download" "$dest" "${file##*/}"
}

fetchFromDir() {
	local url="$1" dest="$2" listing file
	listing=$(curl -fsSL --max-time 90 -A "$userAgent" "${url%/}/" 2>/dev/null)
	[ -n "$listing" ] || return 1
	file=$(printf '%s' "$listing" |
		grep -oiE '[A-Za-z0-9._+-]+-[0-9][A-Za-z0-9._+-]*\.(tar\.(gz|bz2|xz|lz|zst)|tgz|tbz2?|txz|zip)' |
		grep -viE "$preReleaseRe|-doc|-docs|-manual" |
		sort -Vu | tail -n1)
	[ -n "$file" ] || return 1
	fetchTarball "${url%/}/$file" "$dest"
}

fetchInto() {
	local url="$1" dest="$2"
	local host="${url#*://}"
	host="${host%%/*}"
	host="${host,,}"

	local handler
	if [[ $host =~ $gitForgeRe ]]; then
		handler=fetchGit
	elif [[ $host == pypi.org || $host == pypi.python.org ]]; then
		handler=fetchPypi
	elif [[ $host == rubygems.org ]]; then
		handler=fetchGem
	elif [[ $host == sourceforge.net ]]; then
		handler=fetchSourceForge
	elif [[ $url == http://* || $url == https://* || $url == ftp://* ]]; then
		handler=fetchFromDir
	else
		return 1
	fi

	local tmp how
	tmp=$(mktemp -d "$resultsDir/fetch.XXXXXX") || return 1
	if how=$("$handler" "$url" "$tmp") && [ -n "$(ls -A "$tmp" 2>/dev/null)" ]; then
		rm -rf "$tmp/.git"
		if cp -a "$tmp"/. "$dest"/; then
			rm -rf "$tmp"
			printf '%s' "$how"
			return 0
		fi
	fi
	rm -rf "$tmp"
	return 1
}

processOne() {
	local token="$1"
	local pkgName repoVersion repoName
	IFS='@' read -r pkgName repoVersion repoName <<<"$token"
	local cacheKey="${pkgName}@${repoVersion}@${repoName}"
	local cacheEntryFile="$cacheEntriesDir/${cacheKey//[!A-Za-z0-9._+@-]/_}"
	local newest="" tracked="" slackStatus="" fromCache=false lookupFailed=false response status

	if [ "$useCache" = true ] && [ -f "$cacheEntryFile" ]; then
		local cachedSchema cachedTs cachedNewest cachedTracked cachedSlackStatus
		{
			IFS= read -r cachedSchema
			IFS= read -r cachedTs
			IFS= read -r cachedNewest
			IFS= read -r cachedTracked
			IFS= read -r cachedSlackStatus
		} < <(jq -r '(.schema // 0), (.ts // 0), (.newest // ""), (.tracked // ""), (.slackstatus // "")' "$cacheEntryFile" 2>/dev/null)
		if [ "$cachedSchema" = "2" ] && [[ "$cachedTs" =~ ^[0-9]+$ ]] && [ $((runStartTs - cachedTs)) -lt "$cacheTtl" ]; then
			newest="$cachedNewest"
			tracked="$cachedTracked"
			slackStatus="$cachedSlackStatus"
			fromCache=true
		fi
	fi

	if [ "$fromCache" = false ]; then
		local httpCode curlRc
		acquireSlotLock api "$pkgName" "$apiConcurrency"
		response=$(curl -s --max-time 15 -w '\n%{http_code}' -A "$userAgent" "$apiBase/$repoName" 2>/dev/null)
		curlRc=$?
		sleep "$delay"
		releaseSlotLock
		httpCode="${response##*$'\n'}"
		response="${response%$'\n'*}"
		if [ "$curlRc" -eq 0 ] && [ "$httpCode" = "200" ]; then
			local apiShape="" cacheJson="" nowTs
			nowTs=$(date +%s)
			{
				IFS= read -r apiShape
				IFS= read -r newest
				IFS= read -r tracked
				IFS= read -r slackStatus
				IFS= read -r cacheJson
			} < <(jq -r --arg v "$repoVersion" --argjson ts "$nowTs" '
				if type != "array" then "invalid"
				else
					([.[] | select(.status == "newest")][0].version // "") as $n |
					(if length > 0 then "yes" else "no" end) as $t |
					([.[] | select((.repo | startswith("slackware")) and .version == $v)][0].status // "") as $s |
					("array", $n, $t, $s,
						({schema: 2, ts: $ts, newest: $n, tracked: $t, slackstatus: $s} | tojson))
				end' <<<"$response" 2>/dev/null)
			if [ "$apiShape" = "array" ] && [ -n "$cacheJson" ]; then
				local tmpCacheFile
				tmpCacheFile=$(mktemp "${cacheEntryFile}.XXXXXX" 2>/dev/null) &&
					printf '%s\n' "$cacheJson" >"$tmpCacheFile" &&
					mv -f "$tmpCacheFile" "$cacheEntryFile"
			else
				lookupFailed=true
			fi
		else
			lookupFailed=true
		fi
	fi

	if [ "$lookupFailed" = true ]; then
		status="failed"
		newest="?"
	else
		# Trust Repology's own verdict for our exact package version when it
		# has one (and, for outdated, a release to point at); fall back to
		# comparing version strings ourselves otherwise.
		if [ "$slackStatus" = "newest" ]; then
			status="uptodate"
		elif { [ "$slackStatus" = "outdated" ] || [ "$slackStatus" = "legacy" ]; } && [ -n "$newest" ]; then
			status="outdated"
		elif [ "$slackStatus" = "devel" ]; then
			status="newer"
		elif [[ "$slackStatus" =~ ^(ignored|rolling|untrusted|incorrect|noscheme)$ ]]; then
			status="snapshot"
		elif [ -n "$newest" ]; then
			local normRepo="${repoVersion//[_-]/.}" normNewest="${newest//[_-]/.}"
			normRepo="${normRepo,,}"
			normNewest="${normNewest,,}"
			if [ "$normRepo" = "$normNewest" ]; then
				status="uptodate"
			else
				local newer
				newer=$(printf '%s\n%s\n' "$normRepo" "$normNewest" | sort -V | tail -n1)
				if [ "$newer" = "$normNewest" ]; then
					status="outdated"
				else
					status="newer"
				fi
			fi
		elif [ "$tracked" = "yes" ]; then
			status="norelease"
		else
			status="nottracked"
		fi
		[ -n "$newest" ] || newest="-"
	fi

	local upstreamUrl=""
	if [ "$status" = "outdated" ] && [ "$buildEnabled" = true ] && [ -n "$upstreamFile" ]; then
		upstreamUrl=$(lookupUpstream "$pkgName")
	fi

	printf '%s\t%s\t%s\t%s\n' "$status" "$pkgName" "$repoVersion" "$newest" >"$resultsDir/$pkgName.tsv"

	local statusColor
	case "$status" in
	uptodate) statusColor="$green" ;;
	outdated | failed) statusColor="$red" ;;
	nottracked) statusColor="$brown" ;;
	*) statusColor="$yellow" ;;
	esac
	local note=""
	if [ "$status" = "snapshot" ]; then
		note="  ($slackStatus on Repology)"
	fi
	printStatus "$statusColor" "$status" "$pkgName ($repoVersion -> $newest)${note}"

	if [ "$status" = "outdated" ] && [ "$buildEnabled" = true ]; then
		printf '%s\t%s\t%s\t%s\n' "$pkgName" "$repoVersion" "$newest" "$upstreamUrl" >"$buildQueueDir/$pkgName"
	fi
}
export -f processOne
export apiBase userAgent delay useCache cacheTtl cacheEntriesDir resultsDir runStartTs apiConcurrency
export green red yellow brown buildEnabled buildQueueDir

if [ "$total" -gt 0 ]; then
	printf '%s\n' "${toProcess[@]}" | xargs -P "$jobs" -I{} bash -c 'set -uo pipefail; processOne "$@"' _ {}
fi

buildFailures=0
if [ "$buildEnabled" = true ]; then
	buildTokens=()
	for f in "$buildQueueDir"/*; do
		[ -e "$f" ] || continue
		buildTokens+=("$(cat "$f")")
	done
	if [ ${#buildTokens[@]} -gt 0 ]; then
		echo
		echo -e "${bold}${cyan}Fetching + building ${#buildTokens[@]} outdated package(s) from $sourceDir...${reset}"
		for token in "${buildTokens[@]}"; do
			buildPackage "$token" || buildFailures=$((buildFailures + 1))
		done
	fi
fi

declare -A statusCount
for f in "$resultsDir"/*.tsv; do
	[ -e "$f" ] || continue
	IFS=$'\t' read -r status _ _ _ <"$f"
	[ -n "$status" ] || continue
	statusCount[$status]=$((${statusCount[$status]:-0} + 1))
done

outdatedCount=${statusCount[outdated]:-0}
newerCount=${statusCount[newer]:-0}
notTrackedCount=${statusCount[nottracked]:-0}
noReleaseCount=$((${statusCount[norelease]:-0} + ${statusCount[snapshot]:-0}))
upToDate=${statusCount[uptodate]:-0}
failedCount=${statusCount[failed]:-0}

echo
echo -e "${bold}Summary:${reset} $total packages checked, ${red}${outdatedCount} outdated${reset}, ${green}${upToDate} up to date${reset}, ${yellow}${newerCount} ahead of tracker${reset}, ${yellow}${noReleaseCount} without upstream release${reset}, ${brown}${notTrackedCount} not tracked${reset}."
if [ "$failedCount" -gt 0 ]; then
	echo -e "${red}${failedCount} package(s) had a failed lookup (not cached; rerun to retry, or reduce -r / raise -d if rate-limited).${reset}"
fi

if [ "$buildFailures" -gt 0 ]; then
	echo -e "${red}${buildFailures} package(s) failed to build.${reset}" >&2
	exit 1
fi
