/*  -*- Mode: C/l; -*-                                                       */
/*                                                                           */
/*  librosie.h                                                               */
/*                                                                           */
/*  © Copyright IBM Corporation 2016.                                        */
/*  LICENSE: MIT License (https://opensource.org/licenses/mit-license.html)  */
/*  AUTHOR: Jamie A. Jennings                                                */

#define TRUE 1
#define FALSE 0

#define MAXPATHSIZE 4096

#include "lauxlib.h"
#include "lualib.h"

typedef uint8_t * byte_ptr;

struct string {
     uint32_t len;
     byte_ptr ptr;
};

struct stringArray {
     uint32_t n;
     struct string **ptr;
};

struct string *new_string(char *msg, size_t len);
struct string *copy_string_ptr(struct string *src);
void free_string(struct string foo);
void free_string_ptr(struct string *foo);
void free_stringArray(struct stringArray r);

#define CONST_STRING(str) (struct string) {strlen(str), (byte_ptr)str}
#define stringArrayRef(name, pos) (((name).n > (pos)) ? ((name).ptr[(pos)]) : '\0')

struct stringArray initialize(const char *rosie_home);
void finalize();
struct stringArray rosie_api(const char *name, ...);
struct stringArray new_engine(struct string *config);
struct stringArray inspect_engine(struct string *eid_string);
struct stringArray match(struct string *eid_string, struct string *input);
struct stringArray delete_engine(struct string *eid_string);

// TO DO: Change json fcns to take a Lua state reference (or engine) as an arg
//struct stringArray json_decode(struct string *js_string);
//struct stringArray json_encode(struct string *plain_string);

//void print_stringArray(struct stringArray sa, char *caller_name);

#ifndef DEBUG
#define DEBUG 0
#endif

#define LOG(msg) \
     do { if (DEBUG) fprintf(stderr, "%s:%d:%s(): %s", __FILE__, \
			     __LINE__, __func__, msg); } while (0)

#define LOGf(fmt, ...) \
     do { if (DEBUG) fprintf(stderr, "%s:%d:%s(): " fmt, __FILE__, \
			     __LINE__, __func__, __VA_ARGS__); } while (0)

#define LOGstack(L) \
     do { if (DEBUG) stackDump(L); } while (0)

#define LOGprintArray(sa, caller_name) \
     do { if (DEBUG) print_stringArray(sa, caller_name); } while (0)
