/* Stub replacing util/comm-usb.c so ectool builds without libusb.
 * USB transport (ectool --interface=usb) is only used for USB-attached ECs
 * (e.g. detachable keyboards); /dev/cros_ec does not need it. */
#include <stdint.h>
#include <stdio.h>

int parse_vidpid(const char *input, uint16_t *vid_ptr, uint16_t *pid_ptr)
{
	unsigned int vid, pid;

	if (sscanf(input, "%x:%x", &vid, &pid) != 2)
		return 0;
	*vid_ptr = vid;
	*pid_ptr = pid;
	return 1;
}

int comm_init_usb(uint16_t vid, uint16_t pid)
{
	(void)vid;
	(void)pid;
	fprintf(stderr, "USB transport not built in (no libusb)\n");
	return -1;
}

void comm_usb_exit(void)
{
}
