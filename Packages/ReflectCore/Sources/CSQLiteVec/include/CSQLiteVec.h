// Public umbrella header for the statically-linked sqlite-vec extension.
// Deliberately avoids including sqlite3.h/sqlite3ext.h so the Swift importer
// needs no SQLite header search paths; the opaque types match SQLite's ABI.
#ifndef CSQLITEVEC_H
#define CSQLITEVEC_H

typedef struct sqlite3 sqlite3;
typedef struct sqlite3_api_routines sqlite3_api_routines;

int sqlite3_vec_init(sqlite3 *db, char **pzErrMsg,
                     const sqlite3_api_routines *pApi);

#endif
