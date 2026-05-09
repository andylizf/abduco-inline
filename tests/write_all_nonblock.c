#define main abduco_program_main
#include "../c/abduco.c"
#undef main

static void alarm_handler(int sig) {
	(void)sig;
	_exit(99);
}

int main(void) {
	int sv[2];
	if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) == -1)
		return 2;

	int flags = fcntl(sv[0], F_GETFL, 0);
	if (flags == -1 || fcntl(sv[0], F_SETFL, flags | O_NONBLOCK) == -1)
		return 3;

	char fill[4096];
	memset(fill, 'x', sizeof(fill));
	for (;;) {
		ssize_t n = write(sv[0], fill, sizeof(fill));
		if (n == -1) {
			if (errno == EAGAIN || errno == EWOULDBLOCK)
				break;
			return 4;
		}
	}

	signal(SIGALRM, alarm_handler);
	alarm(1);
	ssize_t n = write_all(sv[0], "z", 1);
	alarm(0);

	if (n == 1)
		return 5;
	return 0;
}
