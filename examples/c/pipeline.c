#include <sys/wait.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int write_all(int fd, const void *data, size_t size) {
  const char *bytes = data;
  while (size) {
    ssize_t written = write(fd, bytes, size);
    if (written < 0 && errno == EINTR) continue;
    if (written <= 0) return -1;
    bytes += written;
    size -= (size_t)written;
  }
  return 0;
}

int main(void) {
  const char *afe_path = getenv("AFE");
  if (!afe_path) afe_path = "./build/afe";
  const char *pryon_path = getenv("PRYON");
  if (!pryon_path) pryon_path = "./build/pryon";
  int audio_to_afe[2], afe_to_pryon[2];
  if (pipe(audio_to_afe) != 0 || pipe(afe_to_pryon) != 0) return 1;

  if (fork() == 0) {
    dup2(audio_to_afe[0], STDIN_FILENO);
    dup2(afe_to_pryon[1], STDOUT_FILENO);
    close(audio_to_afe[0]); close(audio_to_afe[1]);
    close(afe_to_pryon[0]); close(afe_to_pryon[1]);
    execl(afe_path, "afe", (char *)0);
    _exit(127);
  }

  if (fork() == 0) {
    dup2(afe_to_pryon[0], STDIN_FILENO);
    close(audio_to_afe[0]); close(audio_to_afe[1]);
    close(afe_to_pryon[0]); close(afe_to_pryon[1]);
    execl(pryon_path, "pryon", (char *)0);
    _exit(127);
  }

  close(audio_to_afe[0]); close(afe_to_pryon[0]); close(afe_to_pryon[1]);
  /* Replace stdin with a microphone or file in a real program. */
  char buffer[8192];
  ssize_t bytes;
  while ((bytes = read(STDIN_FILENO, buffer, sizeof buffer)) > 0) {
    if (write_all(audio_to_afe[1], buffer, (size_t)bytes) != 0) break;
  }
  close(audio_to_afe[1]);
  wait(NULL); wait(NULL);
  return 0;
}
