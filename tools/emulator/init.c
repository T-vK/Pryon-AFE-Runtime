#define _GNU_SOURCE
#include <sys/mount.h>
#include <sys/reboot.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <sys/wait.h>
#include <linux/reboot.h>
#include <unistd.h>
#include <errno.h>
#include <stdio.h>
static void mk(const char *p) { mkdir(p, 0755); }
static void mnt(const char *s, const char *d, const char *t) { mk(d); mount(s,d,t,0,0); }
int main(void) {
  mnt("proc","/proc","proc"); mnt("sysfs","/sys","sysfs"); mnt("devtmpfs","/dev","devtmpfs");
  mk("/dev/socket"); mk("/tmp"); mk("/run"); mk("/var"); mk("/var/run"); mk("/data"); mk("/cache");
  if (mknod("/dev/binder", S_IFCHR|0666, makedev(10,63)) < 0 && errno != EEXIST) perror("mknod binder");
  chmod("/dev/binder",0666);
  pid_t child = fork();
  if (child < 0) { perror("fork emulator-init"); return 127; }
  if (child == 0) {
    execl("/emulator-init.sh","/emulator-init.sh",(char *)0);
    perror("exec emulator-init.sh");
    _exit(127);
  }
  int status = 0;
  while (waitpid(child, &status, 0) < 0 && errno == EINTR) {}
  sync();
  reboot(LINUX_REBOOT_CMD_POWER_OFF);
  reboot(LINUX_REBOOT_CMD_HALT);
  return WIFEXITED(status) ? WEXITSTATUS(status) : 1;
}
