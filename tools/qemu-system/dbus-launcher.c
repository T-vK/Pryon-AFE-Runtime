#define _GNU_SOURCE
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
int main(void) {
  const char *p="/dev/socket/dbus"; int fd=socket(AF_UNIX,SOCK_STREAM,0); if(fd<0){perror("socket");return 1;}
  unlink(p); struct sockaddr_un a; memset(&a,0,sizeof(a)); a.sun_family=AF_UNIX; strncpy(a.sun_path,p,sizeof(a.sun_path)-1);
  if(bind(fd,(struct sockaddr *)&a,sizeof(a))<0){perror("bind");return 1;} chmod(p,0660);
  if(listen(fd,32)<0){perror("listen");return 1;} if(fd!=9&&dup2(fd,9)<0){perror("dup2");return 1;}
  int f=fcntl(9,F_GETFD); if(f>=0) fcntl(9,F_SETFD,f&~FD_CLOEXEC); setenv("ANDROID_SOCKET_dbus","9",1);
  execl("/system/bin/dbus-daemon","/system/bin/dbus-daemon","--system","--nofork",(char *)0); perror("exec dbus-daemon"); return 1;
}
