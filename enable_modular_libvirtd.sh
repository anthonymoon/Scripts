#!/bin/bash

# Stop the monolithic daemon and its socket units
systemctl stop libvirtd.service
systemctl stop libvirtd{,-ro,-admin,-tcp,-tls}.socket

# Disable future start of the monolithic daemon
systemctl disable libvirtd.service
systemctl disable libvirtd{,-ro,-admin,-tcp,-tls}.socket

# Optionally, mask for stronger protection
# systemctl mask libvirtd.service
# systemctl mask libvirtd{,-ro,-admin,-tcp,-tls}.socket

# Enable and start modular daemons
for drv in qemu interface network nodedev nwfilter secret storage; do
	systemctl unmask virt${drv}d.service
	systemctl unmask virt${drv}d{,-ro,-admin}.socket
	systemctl enable virt${drv}d.service
	systemctl enable virt${drv}d{,-ro,-admin}.socket
done

for drv in qemu network nodedev nwfilter secret storage; do
	systemctl start virt${drv}d{,-ro,-admin}.socket
done

# Enable and start the proxy daemon if needed
systemctl unmask virtproxyd.service
systemctl unmask virtproxyd{,-ro,-admin}.socket
systemctl enable virtproxyd.service
systemctl enable virtproxyd{,-ro,-admin}.socket
systemctl start virtproxyd{,-ro,-admin}.socket
systemctl unmask virtproxyd-tls.socket
systemctl enable virtproxyd-tls.socket
systemctl start virtproxyd-tls.socket
