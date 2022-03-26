# external-snapshot-manager
As useful as `libvirt` is, it is not without issues; one of such issues is that while it offers full support to the so-called "internal snapshots", which can be manipulated via commands such as `snapshot-create`, `snapshot-revert` and `snapshot-delete`, snapshots of this type are severely limited:  
+ They necessarily require the original image to be in the `qcow2` format
+ They are slow to create
+ They just don't work with some configurations (e.g. if the VM has multiple disks)  

Conversely, the snapshots defined as "external snapshots" are much more versatile and efficient, but once they are created users are left to their own devices in dealing with them. This utility is just a very simple bash script meant to make handling external snapshots simpler and as close as possible to the "internal snapshot" user experience while maintaining a good degree of versatility.

## Dependencies
Only dependency is `xmlstarlet`, install with `sudo apt install xmlstarlet`.

## Usage
The main script `external_snapshot_manager.sh` receives a command as first parameter and then passes the subsequent parameters to the invoked function. Notice that most of the available functions are designed to be used when the VM is offline; only exception is `commit`, which instead requires the VM to be online because of how the underlying `virsh blockcommit` works.  
The functions which are currently available are:
+ `setup <domain> <path>`: this command should be invoked before any snapshots are created; it is needed to set up a separate `<path>/disks` folder (with `<path>` specified by the user) where all the images used by `<domain>` will be stored, as well as moving the original images ("base" images) there.
+ `create <domain> <name>`: creates snapshot `<name>` for `<domain>`. Notice that "base" is not available for `<name>`, since it is used as a reserved keyword to identify the "base" images.
+ `revert <domain> <name>`: reconfigures `<domain>` to use the images associated with snapshot `<name>`. In order to revert to the original images, specify "base" for `<name>`.
+ `delete <domain> <name>`: deletes snapshot `<name>` for `<domain>`. Notice that the attempt will fail if the snapshot is currently active.
+ `refresh <domain>`: discards all changes to the current active snapshot and restores it to its original state. Does not work for "base" images. This is different from `revert` in that if one has a snapshot they want to use as a base multiple times, reverting to it and using it will only work once. Instead, one should create another snapshot on top of the one they want to preserve and then keep refreshing that other snapshot.
+ `commit <domain> <base> <top>`: this command allows to improve efficiency by reducing the number of snapshots in a chain for `<domain>`; more precisely, it "commits" all the changes which were made in the `<top>` snapshot to the `<base>` snapshot. This makes all snapshots in the chain between `<base>` and `<top>` (including `<top>` itself) unusable, therefore the user should take care to delete those snapshots after running this command.
