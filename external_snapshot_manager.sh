#!/bin/bash

external_snapshot_setup () {
	if [[ $# != 2 ]]; then
		echo "Usage: ${0} setup <domain> <path>"
		return 1
	fi

	local output=`virsh snapshot-list --domain $1`

	if [[ $? != 0 ]]; then
		echo "$output"
		return 1
	fi

	local lines=`echo "$output" | wc -l`
	if [[ $lines -gt 2 ]]; then
		echo "Function should be used before creating any snapshots."
		return 1
	fi

	local diskFolder=`realpath "${2}/disks"`
	output=`mkdir $diskFolder`

	if [[ $? != 0 ]]; then
		echo "$output"
		return 1
	fi

	echo "Created folder ${diskFolder}"

	readarray -t pathsArray < <( virsh domblklist --domain $1 --details | awk 'NR>2 && $2=="disk" {print $4}' )
	local domxml=`virsh dumpxml --domain $1`
	for path in ${pathsArray[@]}; do
		local bname=`basename $path`
		local folder=`dirname $path`
		local name="${bname%.*}"
		local newPath="${diskFolder}/${name}.base"
		output=`mv $path $newPath`
		if [[ $? != 0 ]]; then
			echo "$output"
			return 1
		fi
		echo "Moved ${path} to ${newPath}"
		domxml=`echo -n "$domxml" | xmlstarlet ed -u "/domain/devices/disk[source/@file=\"${path}\"]/source/@file" -v $newPath`
	done
	virsh define <(echo $domxml)

	return 0
}

external_snapshot_create () {
	if [[ $# != 2 ]]; then
		echo "Usage: ${0} create <domain> <name>"
		return 1
	fi

	if [[ $2 == "base" ]]; then
		echo "Cannot create a snapshot with name \"base\"."
		return 1
	fi

	local output=`virsh snapshot-create-as --domain $1 --name $2 --disk-only`

	if [[ $? != 0 ]]; then
		echo "$output"
		return 1
	fi

	return 0
}

external_snapshot_revert () {
	local output

	if [[ $# != 2 ]]; then
		echo "Usage: ${0} revert <domain> <name>"
		return 1
	fi

	if [[ $2 == "base" ]]; then
		output=`virsh dominfo --domain $1`
		if [[ $? != 0 ]]; then
			echo "$output"
			return 1
		fi
	else
		output=`virsh snapshot-info --domain $1 --snapshotname $2`
		if [[ $? != 0 ]]; then
			echo "$output"
			return 1
		fi
	fi

	readarray -t pathsArray < <( virsh domblklist --domain $1 --details | awk 'NR>2 && $2=="disk" {print $4}' )
	local domxml=`virsh dumpxml --domain $1`
	for path in ${pathsArray[@]}; do
		local bname=`basename $path`
		local folder=`dirname $path`
		local ext="${bname#*.}"
		local name="${bname%.*}"
		if [[ $ext == $2 ]]; then
			echo "Can't revert to currently active snapshot!"
			return 1
		else
			local newPath="${folder}/${name}.${2}"
			local diskInfo=`qemu-img info $newPath`
			if [[ $? != 0 ]]; then
				echo $diskInfo
				return 1
			fi
			local diskType=`echo "$diskInfo" | grep "^file format:" | cut -d " " -f 3`
			domxml=`echo -n "$domxml" | xmlstarlet ed -u "/domain/devices/disk[source/@file=\"${path}\"]/driver/@type" -v $diskType`
			domxml=`echo -n "$domxml" | xmlstarlet ed -u "/domain/devices/disk[source/@file=\"${path}\"]/source/@file" -v $newPath`
		fi
	done
	virsh define <(echo $domxml)

	return 0
}

external_snapshot_delete () {
	if [[ $# != 2 ]]; then
		echo "Usage: ${0} delete <domain> <name>"
		return 1
	fi

	if [[ $2 == "base" ]]; then
		echo "Can't delete \"base\" images!"
		return 1
	fi

	local output=`virsh snapshot-info --domain $1 --snapshotname $2`
	if [[ $? != 0 ]]; then
		echo "$output"
		return 1
	fi

	readarray -t pathsArray < <( virsh domblklist --domain $1 --details | awk 'NR>2 && $2=="disk" {print $4}' )
	for path in ${pathsArray[@]}; do
		local bname=`basename $path`
		local folder=`dirname $path`
		local ext="${bname#*.}"
		local name="${bname%.*}"
		local newPath="${folder}/${name}.${2}"
		if [[ $ext == $2 ]]; then
			echo "The snapshot is currently active!"
			return 1
		else 
			rm -f $newPath
			echo "Removed ${newPath}"
		fi
	done

	virsh snapshot-delete --domain $1 --snapshotname $2 --metadata

	return 0
}

external_snapshot_refresh () {
	if [[ $# != 1 ]]; then
		echo "Usage: ${0} delete <domain>"
		return 1
	fi

	local output=`virsh dominfo --domain $1`
	if [[ $? != 0 ]]; then
		echo "$output"
		return 1
	fi

	readarray -t pathsArray < <( virsh domblklist --domain $1 --details | awk 'NR>2 && $2=="disk" {print $4}' )
	for path in ${pathsArray[@]}; do
		local bname=`basename $path`
		local folder=`dirname $path`
		local ext="${bname#*.}"
		local name="${bname%.*}"
		if [[ $ext == "base" ]]; then
			echo "Can't refresh \"base\" images!"
			return 1
		fi
		local backingFile=`qemu-img info $path | grep "backing file:" | cut -d " " -f 3`
		local backingFileBname=`basename $backingFile`
		local backingFileExt="${backingFileBname#*.}"
	done
	external_snapshot_revert $1 $backingFileExt
	if [[ $? != 0 ]]; then
		return 1
	fi
	external_snapshot_delete $1 $ext
	if [[ $? != 0 ]]; then
		return 1
	fi
	external_snapshot_create $1 $ext
	if [[ $? != 0 ]]; then
		return 1
	fi

	return 0
}

external_snapshot_commit () {
	local output

	if [[ $# != 3 ]]; then
		echo "Usage: ${0} <domain> <top_snapshot> <base_snapshot>"
		exit 1
	fi

	local blklist=`virsh domblklist --domain $1 --details`
	readarray -t pathsArray < <( echo -n "$blklist" | awk 'NR>2 && $2=="disk" {print $4}' )
	readarray -t targetsArray < <( echo -n "$blklist" | awk 'NR>2 && $2=="disk" {print $3}' )
	local len=${#pathsArray[@]}
	for ((i=0; i<$len; i++)); do
		local path=${pathsArray[$i]}
		local target=${targetsArray[$i]}
		local bname=`basename $path`
		local folder=`dirname $path`
		local ext="${bname#*.}"
		local name="${bname%.*}"
		local basePath="${folder}/${name}.${3}"
		local topPath="${folder}/${name}.${2}"
		if [[ $ext == $2 ]]; then
			echo "Top snapshot is currently active; pivoting to base."
			output=`virsh blockcommit --domain $1 --path $target --base $basePath --top $topPath --active --pivot`
		else
			output=`virsh blockcommit --domain $1 --path $target --base $basePath --top $topPath`
		fi
		if [[ $? != 0 ]]; then
			echo $output
			return 1
		fi
	done

	return 0
}

if [[ $# < 1 ]]; then
        echo "Usage: ${0} <command>"
        exit 1
fi

ret=0
case $1 in
	setup)
		external_snapshot_setup $2 $3
		ret=$?
	;;
	create)
		external_snapshot_create $2 $3
		ret=$?
	;;
	revert)
		external_snapshot_revert $2 $3
		ret=$?
	;;
	delete)
		external_snapshot_delete $2 $3
		ret=$?
	;;
	refresh)
		external_snapshot_refresh $2
		ret=$?
	;;
	commit)
		external_snapshot_commit $2 $3 $4
		ret=$?
	;;
	*)
		echo "Unknown command."
		ret=1
	;;
esac

exit $ret
