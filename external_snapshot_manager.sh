#!/bin/bash

external_snapshot_setup () {
	local output
	local lines
	local diskFolder
	local pathsArray
	local domxml
	local bname
	local folder
	local name
	local newPath

	if [[ $# != 2 ]]; then
		echo "Usage: ${0} setup <domain> <path>"
		return 1
	fi

	output=`virsh snapshot-list --domain $1 2>&1`
	if [[ $? != 0 ]]; then
		echo -n "$output"
		return 1
	fi

	lines=`echo -n "$output" | wc -l`
	if [[ $lines -gt 2 ]]; then
		echo "Function should be used before creating any snapshots."
		return 1
	fi

	diskFolder=`realpath "${2}/disks"`
	output=`mkdir $diskFolder`

	if [[ $? != 0 ]]; then
		echo -n "$output"
		return 1
	fi

	echo "Created folder ${diskFolder}"

	readarray -t pathsArray < <( virsh domblklist --domain $1 --details | awk 'NR>2 && $2=="disk" {print $4}' )
	domxml=`virsh dumpxml --domain $1`
	for path in ${pathsArray[@]}; do
		bname=`basename $path`
		folder=`dirname $path`
		name="${bname%.*}"
		newPath="${diskFolder}/${name}.base"
		output=`mv $path $newPath 2>&1`
		if [[ $? != 0 ]]; then
			echo -n "$output"
			return 1
		fi
		echo "Moved ${path} to ${newPath}"
		domxml=`echo -n "$domxml" | xmlstarlet ed -u "/domain/devices/disk[source/@file=\"${path}\"]/source/@file" -v $newPath`
	done
	virsh define <(echo $domxml)

	return 0
}

external_snapshot_create () {
	local output 

	if [[ $# != 2 ]]; then
		echo "Usage: ${0} create <domain> <name>"
		return 1
	fi

	if [[ $2 == "base" ]]; then
		echo "Cannot create a snapshot with name \"base\"."
		return 1
	fi

	output=`virsh snapshot-create-as --domain $1 --name $2 --disk-only 2>&1`
	if [[ $? != 0 ]]; then
		echo -n "$output"
		return 1
	fi

	return 0
}

external_snapshot_revert () {
	local output
	local pathsArray
	local domxml
	local bname
	local folder
	local ext
	local name
	local newPath
	local diskInfo
	local diskType

	if [[ $# != 2 ]]; then
		echo "Usage: ${0} revert <domain> <name>"
		return 1
	fi

	if [[ $2 == "base" ]]; then
		output=`virsh dominfo --domain $1 2>&1`
	else
		output=`virsh snapshot-info --domain $1 --snapshotname $2 2>&1`
	fi
	if [[ $? != 0 ]]; then
		echo -n "$output"
		return 1
	fi

	readarray -t pathsArray < <( virsh domblklist --domain $1 --details | awk 'NR>2 && $2=="disk" {print $4}' )
	domxml=`virsh dumpxml --domain $1`
	for path in ${pathsArray[@]}; do
		bname=`basename $path`
		folder=`dirname $path`
		ext="${bname#*.}"
		name="${bname%.*}"
		if [[ $ext == $2 ]]; then
			echo "Can't revert to currently active snapshot!"
			return 1
		else
			newPath="${folder}/${name}.${2}"
			output=`qemu-img info $newPath 2>&1`
			if [[ $? != 0 ]]; then
				echo -n "$output"
				return 1
			fi
			diskType=`echo -n "$output" | grep "^file format:" | cut -d " " -f 3`
			domxml=`echo -n "$domxml" | xmlstarlet ed -u "/domain/devices/disk[source/@file=\"${path}\"]/driver/@type" -v $diskType`
			domxml=`echo -n "$domxml" | xmlstarlet ed -u "/domain/devices/disk[source/@file=\"${path}\"]/source/@file" -v $newPath`
		fi
	done
	virsh define <(echo $domxml)

	return 0
}

external_snapshot_delete () {
	local output
	local pathsArray
	local bname
	local folder
	local ext
	local name
	local newPath

	if [[ $# != 2 ]]; then
		echo "Usage: ${0} delete <domain> <name>"
		return 1
	fi

	if [[ $2 == "base" ]]; then
		echo "Can't delete \"base\" images!"
		return 1
	fi

	output=`virsh snapshot-info --domain $1 --snapshotname $2 2>&1`
	if [[ $? != 0 ]]; then
		echo -n "$output"
		return 1
	fi

	readarray -t pathsArray < <( virsh domblklist --domain $1 --details | awk 'NR>2 && $2=="disk" {print $4}' )
	for path in ${pathsArray[@]}; do
		bname=`basename $path`
		folder=`dirname $path`
		ext="${bname#*.}"
		name="${bname%.*}"
		newPath="${folder}/${name}.${2}"
		if [[ $ext == $2 ]]; then
			echo "The snapshot is currently active!"
			return 1
		else 
			if ! [[ -f $newPath ]]; then
				echo "File ${newPath} does not exist!"
				return 1
			fi
			rm -f $newPath
			echo "Removed ${newPath}"
		fi
	done

	virsh snapshot-delete --domain $1 --snapshotname $2 --metadata

	return 0
}

external_snapshot_refresh () {
	local output
	local pathsArray
	local bname
	local folder
	local ext
	local name
	local backingFile
	local backingFileBname
	local backingFileExt

	if [[ $# != 1 ]]; then
		echo "Usage: ${0} delete <domain>"
		return 1
	fi

	output=`virsh dominfo --domain $1 2>&1`
	if [[ $? != 0 ]]; then
		echo -n "$output"
		return 1
	fi

	readarray -t pathsArray < <( virsh domblklist --domain $1 --details | awk 'NR>2 && $2=="disk" {print $4}' )
	for path in ${pathsArray[@]}; do
		bname=`basename $path`
		folder=`dirname $path`
		ext="${bname#*.}"
		name="${bname%.*}"
		if [[ $ext == "base" ]]; then
			echo "Can't refresh \"base\" images!"
			return 1
		fi
		backingFile=`qemu-img info $path | grep "backing file:" | cut -d " " -f 3`
		backingFileBname=`basename $backingFile`
		backingFileExt="${backingFileBname#*.}"
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
	local pathsArray
	local targetsArray
	local len
	local path
	local target
	local bname
	local folder
	local ext 
	local name
	local basePath
	local topPath

	if [[ $# != 3 ]]; then
		echo "Usage: ${0} <domain> <top_snapshot> <base_snapshot>"
		exit 1
	fi

	output=`virsh domblklist --domain $1 --details 2>&1`
	if [[ $? != 0 ]]; then
		echo -n "$output"
		return 1
	fi

	readarray -t pathsArray < <( echo -n "$output" | awk 'NR>2 && $2=="disk" {print $4}' )
	readarray -t targetsArray < <( echo -n "$output" | awk 'NR>2 && $2=="disk" {print $3}' )
	len=${#pathsArray[@]}
	for ((i=0; i<$len; i++)); do
		path=${pathsArray[$i]}
		target=${targetsArray[$i]}
		bname=`basename $path`
		folder=`dirname $path`
		ext="${bname#*.}"
		name="${bname%.*}"
		basePath="${folder}/${name}.${3}"
		topPath="${folder}/${name}.${2}"
		if [[ $ext == $2 ]]; then
			echo "Top snapshot is currently active; pivoting to base."
			output=`virsh blockcommit --domain $1 --path $target --base $basePath --top $topPath --active --pivot 2>&1`
		else
			output=`virsh blockcommit --domain $1 --path $target --base $basePath --top $topPath 2>&1`
		fi
		if [[ $? != 0 ]]; then
			echo -n "$output"
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
