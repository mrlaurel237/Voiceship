# Convertit le modèle de la taille de LLVC en Core ML (mlprogram, iOS 15+) pour le mesurer sur iPhone.
# Entrées : x (1,1,208) + états du streaming ; sorties : y + nouveaux états.
import sys, torch, coremltools as ct
sys.path.insert(0, __import__('os').path.dirname(__file__))
import importlib.util
spec = importlib.util.spec_from_file_location("b", __import__('os').path.join(__import__('os').path.dirname(__file__), "llvc_proxy_bench.py"))
src = open(spec.origin).read().split("m = Proxy().eval()")[0]
exec(src)
class Flat(torch.nn.Module):
    def __init__(s):
        super().__init__(); s.m = Proxy().eval()
    def forward(s, x, pre, inb, b0, b1, b2, b3, b4, b5, b6, b7, ctx):
        y, (p, i, nb, c) = s.m(x, (pre, inb, [b0, b1, b2, b3, b4, b5, b6, b7], ctx))
        return (y, p, i, *nb, c)
f = Flat().eval()
ex = (torch.randn(1, 1, CH * L), torch.zeros(1, 1, 24), torch.zeros(1, 1, 2 * L),
      *[torch.zeros(1, ENC, 2 * 2 ** i) for i in range(NENC)], torch.zeros(1, CTX, DEC))
names = ["x", "pre", "inb"] + [f"b{i}" for i in range(NENC)] + ["ctx"]
with torch.inference_mode():
    tr = torch.jit.trace(f, ex)
mlm = ct.convert(tr, inputs=[ct.TensorType(name=n, shape=t.shape) for n, t in zip(names, ex)],
                 outputs=[ct.TensorType(name=n) for n in ["y", "o_pre", "o_inb"] + [f"o_b{i}" for i in range(NENC)] + ["o_ctx"]],
                 convert_to="mlprogram", minimum_deployment_target=ct.target.iOS15,
                 compute_precision=ct.precision.FLOAT32)
mlm.short_description = "VoiceShift — modèle de test (taille LLVC, poids aléatoires) pour mesurer la vitesse"
mlm.save(sys.argv[1])
print("ok", sys.argv[1])
