#include <fcntl.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char *argv[])
{
	struct flock fl;
	int fd;

	if (argc != 2)
		return 2;
	fd = open(argv[1], O_RDWR);
	if (fd == -1)
		return 1;
	memset(&fl, 0, sizeof(fl));
	fl.l_type = F_WRLCK;
	fl.l_whence = SEEK_SET;
	if (fcntl(fd, F_SETLK, &fl) == -1)
		return 1;
	if (write(1, "locked\n", 7) != 7)
		return 1;
	close(1);
	for (;;)
		pause();
}
