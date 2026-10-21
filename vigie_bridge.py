"""Pont RPyC « classic » de Vigie (port 8001), exécuté par le Python Windows sous Wine.

Vigie s'y connecte avec rpyc.classic.connect(host, 8001) et utilise conn.modules["MetaTrader5"].
Lancé et relancé par /Metatrader/start.sh (journal /config/vigie-mt5.log)."""
import sys

from rpyc.core.service import SlaveService
from rpyc.utils.server import ThreadedServer

port = int(sys.argv[1]) if len(sys.argv) > 1 else 8001
print(f"[vigie-bridge] Python {sys.version.split()[0]} · pont RPyC classic sur 0.0.0.0:{port}", flush=True)
try:
    import MetaTrader5  # noqa: F401  (vérification : le module doit être importable)
    print(f"[vigie-bridge] MetaTrader5 {getattr(MetaTrader5, '__version__', '?')} importable", flush=True)
except Exception as e:  # noqa: BLE001
    print(f"[vigie-bridge] ATTENTION : import MetaTrader5 impossible : {e!r}", flush=True)
ThreadedServer(SlaveService, hostname="0.0.0.0", port=port, reuse_addr=True,
               protocol_config={"allow_all_attrs": True, "allow_pickle": True,
                                "sync_request_timeout": 120}).start()
