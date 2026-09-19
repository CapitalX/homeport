#ifndef CDISCLAIM_H
#define CDISCLAIM_H

#include <spawn.h>

/*
 * Private libSystem SPI. Declaring the prototype here lets Swift call it; the
 * symbol is resolved against libSystem at runtime (two-level namespace).
 *
 * When set on a posix_spawnattr_t used with POSIX_SPAWN_SETEXEC, the re-exec'd
 * image becomes its OWN responsible process for TCC purposes, instead of
 * inheriting responsibility from whichever app launched it (Claude Desktop,
 * Terminal, Cursor, ...). macOS then attributes Calendar/Reminders/Contacts
 * permission to THIS binary's code-signing identity, so the grant is durable
 * and portable across every MCP host.
 *
 * This is the same mechanism FradSer/mcp-server-apple-events uses in its
 * standalone `event-disclaim` helper; here it runs in-process so the whole
 * tool stays a single binary.
 */
int responsibility_spawnattrs_setdisclaim(posix_spawnattr_t *attrs, int disclaim);

#endif /* CDISCLAIM_H */
