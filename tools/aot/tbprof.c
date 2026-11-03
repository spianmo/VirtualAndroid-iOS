/*
 * tbprof: QEMU TCG plugin that records every translated TB with an AOT-style
 * content key and counts its executions (inline per-vCPU counters).
 *
 *   -plugin libtbprof.dylib,out=/path/prof.tsv
 *
 * Key ("bkey") = aot_bkey(guest insn bytes, page offset of pc, byte size), the
 * same function QEMU's AOT runtime uses (engine/qemu-aot/tcg/aot.c) before it
 * mixes in flags/cs_base/cflags.  Output TSV (one row per distinct bkey):
 *   bkey vaddr off size ninsns kernel ntrans execs
 * A periodic dump (every `period` seconds, default 30) lets a run be killed.
 */
#include <glib.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include <qemu-plugin.h>

QEMU_PLUGIN_EXPORT int qemu_plugin_version = QEMU_PLUGIN_VERSION;

/* Must match aot_bkey() in engine/qemu-aot/tcg/aot.c */
static uint64_t aot_bkey(const uint8_t *p, size_t n, uint32_t off)
{
    uint64_t h = 0xcbf29ce484222325ull;
    for (size_t i = 0; i < n; i++) {
        h ^= p[i];
        h *= 0x100000001b3ull;
    }
    h ^= ((uint64_t)off << 32) | (uint64_t)n;
    h *= 0x9e3779b97f4a7c15ull;
    h ^= h >> 29;
    return h;
}

typedef struct {
    uint64_t bkey, vaddr;
    uint32_t off, size, ninsns, ntrans;
    struct qemu_plugin_scoreboard *sb;
} Rec;

static GMutex lock;
static GHashTable *recs;      /* bkey -> Rec* */
static char *out_path;
static int period = 30;
static time_t last_dump;

static void dump(void)
{
    char tmp[4096];
    snprintf(tmp, sizeof(tmp), "%s.tmp", out_path);
    FILE *f = fopen(tmp, "w");
    if (!f) {
        return;
    }
    GHashTableIter it;
    gpointer k, v;
    g_hash_table_iter_init(&it, recs);
    while (g_hash_table_iter_next(&it, &k, &v)) {
        Rec *r = v;
        uint64_t n = qemu_plugin_u64_sum(qemu_plugin_scoreboard_u64(r->sb));
        fprintf(f, "%016" PRIx64 "\t%016" PRIx64 "\t%x\t%u\t%u\t%d\t%u\t%" PRIu64 "\n",
                r->bkey, r->vaddr, r->off, r->size, r->ninsns,
                (int)(r->vaddr >> 63), r->ntrans, n);
    }
    fclose(f);
    rename(tmp, out_path);
}

static void vcpu_tb_trans(qemu_plugin_id_t id, struct qemu_plugin_tb *tb)
{
    size_t n = qemu_plugin_tb_n_insns(tb);
    uint64_t pc = qemu_plugin_tb_vaddr(tb);
    uint8_t buf[4096];
    size_t len = 0;
    for (size_t i = 0; i < n; i++) {
        struct qemu_plugin_insn *insn = qemu_plugin_tb_get_insn(tb, i);
        size_t sz = qemu_plugin_insn_size(insn);
        if (len + sz > sizeof(buf)) {
            break;
        }
        len += qemu_plugin_insn_data(insn, buf + len, sz);
    }
    uint64_t key = aot_bkey(buf, len, (uint32_t)(pc & 0xfff));

    g_mutex_lock(&lock);
    Rec *r = g_hash_table_lookup(recs, &key);
    if (!r) {
        r = g_new0(Rec, 1);
        r->bkey = key;
        r->vaddr = pc;
        r->off = pc & 0xfff;
        r->size = len;
        r->ninsns = n;
        r->sb = qemu_plugin_scoreboard_new(sizeof(uint64_t));
        g_hash_table_insert(recs, &r->bkey, r);
    }
    r->ntrans++;
    time_t now = time(NULL);
    if (now - last_dump >= period) {
        last_dump = now;
        dump();
    }
    g_mutex_unlock(&lock);

    qemu_plugin_register_vcpu_tb_exec_inline_per_vcpu(
        tb, QEMU_PLUGIN_INLINE_ADD_U64, qemu_plugin_scoreboard_u64(r->sb), 1);
}

static void plugin_exit(qemu_plugin_id_t id, void *p)
{
    g_mutex_lock(&lock);
    dump();
    g_mutex_unlock(&lock);
}

QEMU_PLUGIN_EXPORT
int qemu_plugin_install(qemu_plugin_id_t id, const qemu_info_t *info,
                        int argc, char **argv)
{
    out_path = g_strdup("tbprof.tsv");
    for (int i = 0; i < argc; i++) {
        if (g_str_has_prefix(argv[i], "out=")) {
            out_path = g_strdup(argv[i] + 4);
        } else if (g_str_has_prefix(argv[i], "period=")) {
            period = atoi(argv[i] + 7);
        }
    }
    recs = g_hash_table_new(g_int64_hash, g_int64_equal);
    last_dump = time(NULL);
    qemu_plugin_register_vcpu_tb_trans_cb(id, vcpu_tb_trans);
    qemu_plugin_register_atexit_cb(id, plugin_exit, NULL);
    return 0;
}
