#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#include "config.h"

#ifndef VERSION
#define VERSION "unknown"
#endif

#ifndef PATH_MAX
#define PATH_MAX 4096
#endif

#define HOST_BUF 256

enum { STATE_DEAD, STATE_ALIVE };

struct record {
	char *argbuf;
	char *cwd;
	char **argv;
	size_t argc;
};

static void vmsg(const char *fmt, va_list ap)
{
	int err = errno;
	size_t len = strlen(fmt);

	fputs("reduco: ", stderr);
	vfprintf(stderr, fmt, ap);
	if (len > 0 && fmt[len - 1] == ':')
		fprintf(stderr, " %s", strerror(err));
	fputc('\n', stderr);
}

void warn(const char *fmt, ...)
{
	va_list ap;

	va_start(ap, fmt);
	vmsg(fmt, ap);
	va_end(ap);
}

void die(const char *fmt, ...)
{
	va_list ap;

	va_start(ap, fmt);
	vmsg(fmt, ap);
	va_end(ap);
	exit(EXIT_FAILURE);
}

static void usage(void)
{
	fputs("usage: reduco [-d dir]\n"
	      "       reduco [-d dir] -p name\n"
	      "       reduco [-d dir] -x name\n"
	      "       reduco -v\n", stderr);
	exit(EXIT_FAILURE);
}

static void version(void)
{
	puts("reduco-" VERSION);
	if (fflush(stdout) == EOF || ferror(stdout))
		die("write:");
	exit(EXIT_SUCCESS);
}

static void *xrealloc(void *p, size_t n)
{
	p = realloc(p, n ? n : 1);
	if (!p)
		die("realloc:");
	return p;
}

static char *xstrdup(const char *s)
{
	char *p = xrealloc(NULL, strlen(s) + 1);

	return strcpy(p, s);
}

static const char *host(void)
{
	static char buf[HOST_BUF];

	if (buf[0] == '\0') {
		if (gethostname(buf, sizeof(buf) - 1) == -1)
			die("gethostname:");
		if (buf[0] == '\0' || strchr(buf, '/'))
			die("invalid hostname");
	}
	return buf;
}

static const char *store_dir(const char *opt)
{
	static char path[PATH_MAX];
	const char *env, *home;
	int n;

	if (opt) {
		if (*opt == '\0')
			die("empty directory name");
		return opt;
	}
	env = getenv(REDUCO_DIR_ENV);
	if (env && *env)
		return env;
	home = getenv("HOME");
	if (!home || *home == '\0')
		die("HOME is not set");
	n = snprintf(path, sizeof(path), "%s/%s", home, REDUCO_DIR_DEFAULT);
	if (n < 0 || (size_t)n >= sizeof(path))
		die("%s: path too long", home);
	return path;
}

static void store_check(const char *dir)
{
	struct stat st;

	if (mkdir(dir, 0700) == -1 && errno != EEXIST)
		die("%s:", dir);
	if (stat(dir, &st) == -1)
		die("%s:", dir);
	if (!S_ISDIR(st.st_mode))
		die("%s: not a directory", dir);
	if (st.st_uid != geteuid())
		die("%s: not owned by you", dir);
	if (st.st_mode & (S_IWGRP | S_IWOTH))
		die("%s: writable by group or others", dir);
}

static int name_valid(const char *name)
{
	return name[0] != '\0' && name[0] != '.' &&
	       strspn(name, NAME_CHARS) == strlen(name);
}

static void record_path(char *out, size_t size, const char *dir,
                        const char *name, const char *file)
{
	int n;

	if (file)
		n = snprintf(out, size, "%s/%s@%s/%s", dir, name, host(), file);
	else
		n = snprintf(out, size, "%s/%s@%s", dir, name, host());
	if (n < 0 || (size_t)n >= size)
		die("%s: path too long", name);
}

static void record_require(const char *dir, const char *name)
{
	char path[PATH_MAX];
	struct stat st;

	record_path(path, sizeof(path), dir, name, NULL);
	if (lstat(path, &st) == -1) {
		if (errno == ENOENT)
			die("%s: no such record", name);
		die("%s:", name);
	}
	if (!S_ISDIR(st.st_mode))
		die("%s: no such record", name);
}

static char *read_file(const char *path, size_t *len)
{
	char *buf = NULL;
	size_t used = 0, cap = 0;
	ssize_t n;
	int fd, err;

	fd = open(path, O_RDONLY | O_CLOEXEC);
	if (fd == -1)
		return NULL;
	for (;;) {
		if (used == cap) {
			cap = cap ? cap * 2 : 512;
			buf = xrealloc(buf, cap + 1);
		}
		n = read(fd, buf + used, cap - used);
		if (n == -1) {
			if (errno == EINTR)
				continue;
			err = errno;
			close(fd);
			free(buf);
			errno = err;
			return NULL;
		}
		if (n == 0)
			break;
		used += (size_t)n;
	}
	close(fd);
	buf[used] = '\0';
	*len = used;
	return buf;
}

static void record_free(struct record *rec)
{
	free(rec->argbuf);
	free(rec->cwd);
	free(rec->argv);
	memset(rec, 0, sizeof(*rec));
}

static int record_load(const char *dir, const char *name, struct record *rec)
{
	char path[PATH_MAX];
	size_t len, i;
	char *p;

	memset(rec, 0, sizeof(*rec));

	record_path(path, sizeof(path), dir, name, "argv");
	rec->argbuf = read_file(path, &len);
	if (!rec->argbuf) {
		warn("%s: argv:", name);
		return -1;
	}
	if (len == 0) {
		warn("%s: argv is empty", name);
		record_free(rec);
		return -1;
	}
	for (p = rec->argbuf; p < rec->argbuf + len; p += strlen(p) + 1)
		rec->argc++;
	rec->argv = xrealloc(NULL, (rec->argc + 1) * sizeof(char *));
	p = rec->argbuf;
	for (i = 0; i < rec->argc; i++) {
		rec->argv[i] = p;
		p += strlen(p) + 1;
	}
	rec->argv[rec->argc] = NULL;

	record_path(path, sizeof(path), dir, name, "cwd");
	rec->cwd = read_file(path, &len);
	if (!rec->cwd) {
		warn("%s: cwd:", name);
		record_free(rec);
		return -1;
	}
	if (len > 0 && rec->cwd[len - 1] == '\n')
		rec->cwd[--len] = '\0';
	if (len == 0) {
		warn("%s: cwd is empty", name);
		record_free(rec);
		return -1;
	}
	return 0;
}

static int lock_open(const char *dir, const char *name)
{
	char path[PATH_MAX];

	record_path(path, sizeof(path), dir, name, "lock");
	return open(path, O_RDWR | O_CLOEXEC);
}

static int lock_state(int fd, pid_t *pid)
{
	struct flock fl;

	memset(&fl, 0, sizeof(fl));
	fl.l_type = F_WRLCK;
	fl.l_whence = SEEK_SET;
	if (fcntl(fd, F_GETLK, &fl) == -1)
		return -1;
	if (fl.l_type == F_UNLCK)
		return 0;
	*pid = fl.l_pid;
	return 1;
}

static int lock_try(int fd)
{
	struct flock fl;

	memset(&fl, 0, sizeof(fl));
	fl.l_type = F_WRLCK;
	fl.l_whence = SEEK_SET;
	if (fcntl(fd, F_SETLK, &fl) == 0)
		return 0;
	if (errno == EACCES || errno == EAGAIN)
		return 1;
	return -1;
}

static int record_state(const char *dir, const char *name, pid_t *pid)
{
	int fd, held;

	fd = lock_open(dir, name);
	if (fd == -1)
		return STATE_DEAD;
	held = lock_state(fd, pid);
	close(fd);
	return held == 1 ? STATE_ALIVE : STATE_DEAD;
}

static void sanitize(char *s)
{
	for (; *s; s++)
		if (iscntrl((unsigned char)*s))
			*s = '?';
}

static char *join_argv(const struct record *rec)
{
	size_t i, len = 1;
	char *out, *p;

	for (i = 0; i < rec->argc; i++)
		len += strlen(rec->argv[i]) + 1;
	out = xrealloc(NULL, len);
	p = out;
	for (i = 0; i < rec->argc; i++) {
		if (i > 0)
			*p++ = ' ';
		p += sprintf(p, "%s", rec->argv[i]);
	}
	*p = '\0';
	sanitize(out);
	return out;
}

static char *died_info(const char *dir, const char *name)
{
	char path[PATH_MAX];
	char *buf, *nl;
	size_t len;

	record_path(path, sizeof(path), dir, name, "died");
	buf = read_file(path, &len);
	if (!buf)
		return xstrdup("-");
	nl = strchr(buf, '\n');
	if (nl)
		*nl = '\0';
	sanitize(buf);
	if (buf[0] == '\0') {
		free(buf);
		return xstrdup("-");
	}
	return buf;
}

static int list_one(const char *dir, const char *name)
{
	struct record rec;
	pid_t pid = 0;
	char info[32];
	char *died = NULL, *cmd;
	const char *state;

	if (record_load(dir, name, &rec) == -1)
		return -1;
	if (record_state(dir, name, &pid) == STATE_ALIVE) {
		state = "alive";
		snprintf(info, sizeof(info), "%ld", (long)pid);
	} else {
		state = "dead";
		died = died_info(dir, name);
	}
	sanitize(rec.cwd);
	cmd = join_argv(&rec);
	printf("%s\t%s\t%s\t%s\t%s\n", state, name, died ? died : info,
	       rec.cwd, cmd);
	free(cmd);
	free(died);
	record_free(&rec);
	return 0;
}

static int cmp_names(const void *a, const void *b)
{
	return strcmp(*(char *const *)a, *(char *const *)b);
}

static void cmd_list(const char *dir)
{
	DIR *d;
	struct dirent *e;
	struct stat st;
	char path[PATH_MAX];
	char **names = NULL;
	size_t n = 0, cap = 0, i, len;
	const char *at, *h = host();
	char *name;

	d = opendir(dir);
	if (!d)
		die("%s:", dir);
	while ((e = readdir(d)) != NULL) {
		if (e->d_name[0] == '.')
			continue;
		at = strchr(e->d_name, '@');
		if (!at || strcmp(at + 1, h) != 0)
			continue;
		len = (size_t)(at - e->d_name);
		name = xrealloc(NULL, len + 1);
		memcpy(name, e->d_name, len);
		name[len] = '\0';
		if (!name_valid(name)) {
			free(name);
			continue;
		}
		record_path(path, sizeof(path), dir, name, NULL);
		if (lstat(path, &st) == -1 || !S_ISDIR(st.st_mode)) {
			free(name);
			continue;
		}
		if (n == cap) {
			cap = cap ? cap * 2 : 16;
			names = xrealloc(names, cap * sizeof(char *));
		}
		names[n++] = name;
	}
	closedir(d);

	qsort(names, n, sizeof(char *), cmp_names);
	for (i = 0; i < n; i++) {
		list_one(dir, names[i]);
		free(names[i]);
	}
	free(names);
}

static void quote(const char *s)
{
	putchar('\'');
	for (; *s; s++) {
		if (*s == '\'')
			fputs("'\\''", stdout);
		else
			putchar(*s);
	}
	putchar('\'');
}

static void cmd_print(const char *dir, const char *name)
{
	struct record rec;
	size_t i;

	record_require(dir, name);
	if (record_load(dir, name, &rec) == -1)
		exit(EXIT_FAILURE);
	fputs("cd -- ", stdout);
	quote(rec.cwd);
	fputs(" && exec", stdout);
	for (i = 0; i < rec.argc; i++) {
		putchar(' ');
		quote(rec.argv[i]);
	}
	putchar('\n');
	record_free(&rec);
}

static int rmtree(const char *path)
{
	struct stat st;
	struct dirent *e;
	char child[PATH_MAX];
	DIR *d;
	int n, err, removed;

	if (lstat(path, &st) == -1)
		return -1;
	if (!S_ISDIR(st.st_mode))
		return unlink(path);
	d = opendir(path);
	if (!d)
		return -1;
	do {
		removed = 0;
		rewinddir(d);
		while ((e = readdir(d)) != NULL) {
			if (strcmp(e->d_name, ".") == 0 ||
			    strcmp(e->d_name, "..") == 0)
				continue;
			n = snprintf(child, sizeof(child), "%s/%s", path,
			             e->d_name);
			if (n < 0 || (size_t)n >= sizeof(child)) {
				errno = ENAMETOOLONG;
				goto fail;
			}
			if (rmtree(child) == -1)
				goto fail;
			removed++;
		}
	} while (removed > 0);
	closedir(d);
	return rmdir(path);
fail:
	err = errno;
	closedir(d);
	errno = err;
	return -1;
}

static void cmd_expunge(const char *dir, const char *name)
{
	char path[PATH_MAX];
	pid_t pid = 0;
	int fd, r;

	record_require(dir, name);
	fd = lock_open(dir, name);
	if (fd == -1 && errno != ENOENT)
		die("%s: lock:", name);
	if (fd != -1) {
		r = lock_try(fd);
		if (r == -1)
			die("%s: lock:", name);
		if (r == 1) {
			if (lock_state(fd, &pid) == 1)
				die("%s: alive (pid %ld)", name, (long)pid);
			die("%s: alive", name);
		}
	}
	record_path(path, sizeof(path), dir, name, NULL);
	if (rmtree(path) == -1)
		die("%s: remove:", name);
	if (fd != -1)
		close(fd);
}

int main(int argc, char *argv[])
{
	const char *dirarg = NULL, *name = NULL, *dir;
	int opt, mode = 'l';

	while ((opt = getopt(argc, argv, "vd:p:x:")) != -1) {
		switch (opt) {
		case 'v':
			version();
			break;
		case 'd':
			dirarg = optarg;
			break;
		case 'p':
		case 'x':
			if (mode != 'l')
				usage();
			mode = opt;
			name = optarg;
			break;
		default:
			usage();
		}
	}
	if (optind != argc)
		usage();

	if (name && !name_valid(name))
		die("%s: invalid name", name);
	dir = store_dir(dirarg);
	store_check(dir);

	switch (mode) {
	case 'p':
		cmd_print(dir, name);
		break;
	case 'x':
		cmd_expunge(dir, name);
		break;
	default:
		cmd_list(dir);
	}

	if (fflush(stdout) == EOF || ferror(stdout))
		die("write:");
	return EXIT_SUCCESS;
}
