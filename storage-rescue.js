// Cyanide Storage Rescue
// Requires the Storage Rescue IPA built by .github/workflows/storage-rescue.yml
// Actual removal uses POSIX unlink()/rmdir().
// @param: switch | executeNow | ELIMINAR /var/mobile/Documents/test | false
// @param: number | delayMs | Pausa por operación (ms) | 25 | 10-1000

(() => {
    const ROOT = "/var/mobile/Documents/test";
    let delay = Number(delayMs) || 25;
    if (delay < 10) delay = 10;
    if (delay > 1000) delay = 1000;

    function p(v) {
        const s = String(v || "0x0");
        if (s.indexOf("0x") === 0) return parseInt(s.slice(2), 16) || 0;
        return Number(s) || 0;
    }

    function fail(op, path) {
        log(op + " FAILED errno=" + sr_errno() +
            " (" + sr_strerror() + ") backend=" + sr_backend() +
            " path=" + path);
    }

    log("=== STORAGE RESCUE ===");
    log("Target: " + ROOT);

    if (!executeNow) {
        log("SAFE MODE: executeNow=OFF. No se eliminó nada.");
        log("Activa ELIMINAR /var/mobile/Documents/test para ejecutar.");
        return;
    }

    const fmClass = r_class("NSFileManager");
    const fm = r_msg2(fmClass, "defaultManager");
    const root = r_nsstr(ROOT);

    if (!p(r_msg2(fm, "fileExistsAtPath:", root))) {
        log("La ruta no existe.");
        r_msg2(root, "release");
        return;
    }

    const en = r_msg2(fm, "enumeratorAtPath:", root);
    if (!p(en)) {
        log("ERROR: no pude crear NSDirectoryEnumerator.");
        r_msg2(root, "release");
        return;
    }
    r_msg2(en, "retain");

    const entries = [];
    let scanned = 0;
    let scanTimer = 0;

    log("Fase 1/2: enumerando sin borrar...");
    scanTimer = setInterval(() => {
        const relPtr = r_msg2(en, "nextObject");
        if (!p(relPtr)) {
            clearInterval(scanTimer);
            r_msg2(en, "release");
            log("Enumeración terminada: " + entries.length + " entradas.");
            setTimeout(startDelete, 250);
            return;
        }

        const rel = r_read_str(relPtr);
        if (rel && rel.indexOf("..") === -1) entries.push(rel);
        scanned++;
        if ((scanned % 100) === 0) log("Enumeradas: " + scanned);
    }, delay);

    function startDelete() {
        log("Fase 2/2: POSIX unlink/rmdir...");
        let i = entries.length - 1;
        let removedFiles = 0;
        let removedDirs = 0;
        let failed = 0;
        let done = 0;

        const delTimer = setInterval(() => {
            if (i < 0) {
                clearInterval(delTimer);

                const rootRC = Number(sr_rmdir(ROOT));
                if (rootRC === 0) {
                    removedDirs++;
                    log("ROOT eliminado con rmdir().");
                } else {
                    failed++;
                    fail("rmdir(root)", ROOT);
                }

                log("=== RESULTADO ===");
                log("Entradas: " + entries.length);
                log("Archivos/symlinks eliminados: " + removedFiles);
                log("Directorios eliminados: " + removedDirs);
                log("Fallos: " + failed);

                const existsAfter = p(r_msg2(fm, "fileExistsAtPath:", root));
                log("Root existe al final: " + (existsAfter ? "SI" : "NO"));
                if (!existsAfter) log("SUCCESS: limpieza completada.");

                r_msg2(root, "release");
                return;
            }

            const rel = entries[i--];
            const full = ROOT + "/" + rel;

            const urc = Number(sr_unlink(full));
            if (urc === 0) {
                removedFiles++;
            } else {
                const rrc = Number(sr_rmdir(full));
                if (rrc === 0) {
                    removedDirs++;
                } else {
                    failed++;
                    if (failed <= 30) fail("unlink+rmdir", full);
                }
            }

            done++;
            if ((done % 100) === 0) {
                log("Borradas/procesadas: " + done + "/" + entries.length +
                    " files=" + removedFiles + " dirs=" + removedDirs +
                    " fail=" + failed);
            }
        }, delay);
    }
})();
