//
//  AntiDetection.m
//  3105
//
//  Prevents the app from being flagged as jailbroken by common
//  jailbreak-detection checks. Safe because the app never forks.
//
//  Defining fork() in our own binary overrides the system call for this
//  process only. Other processes are unaffected.
//

#import <unistd.h>
#import <errno.h>

// Any fork() call from this process fails immediately.
// This defeats jailbreak-detection tests that check whether fork() succeeds.
pid_t fork(void) {
    errno = EAGAIN;
    return -1;
}
