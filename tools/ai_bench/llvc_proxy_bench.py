# Mesure du coût d'un modèle de la taille de LLVC (Waveformer adapté, arXiv 2311.00873).
# Les poids sont aléatoires : le temps de calcul ne dépend que de l'architecture.
# Hyperparamètres : ceux de la configuration publiée de LLVC (L=16, enc_dim=512, 8 couches
# dilatées, dec_dim=256, 1 couche de décodeur transformer, morceaux de 13 trames = 13 ms à 16 kHz)
# + un « prenet » convolutif causal.
import time, torch, torch.nn as nn, sys
torch.set_num_threads(1)
L, ENC, NENC, DEC, CH, CTX = 16, 512, 8, 256, 13, 13

class DSConv(nn.Module):              # conv dilatée causale séparable (cœur de l'encodeur Waveformer)
    def __init__(s, c, d):
        super().__init__(); s.dw = nn.Conv1d(c, c, 3, dilation=d, groups=c); s.pw = nn.Conv1d(c, c, 1); s.n = nn.LayerNorm(c); s.pad = 2 * d
    def forward(s, x, buf):            # buf : contexte passé mis en cache (streaming)
        xx = torch.cat([buf, x], -1); nb = xx[..., -s.pad:]
        y = s.pw(torch.relu(s.dw(xx)))
        return x + s.n(y.transpose(1, 2)).transpose(1, 2), nb

class MHA(nn.Module):                  # attention multi-têtes écrite à la main (convertible en Core ML)
    def __init__(s, d, h):
        super().__init__(); s.h = h; s.q = nn.Linear(d, d); s.k = nn.Linear(d, d); s.v = nn.Linear(d, d); s.o = nn.Linear(d, d)
    def forward(s, x, mem):
        D = s.o.in_features; hd = D // s.h         # tailles fixes (pas de forme dynamique)
        q = s.q(x).reshape(1, -1, s.h, hd).transpose(1, 2)
        k = s.k(mem).reshape(1, -1, s.h, hd).transpose(1, 2)
        v = s.v(mem).reshape(1, -1, s.h, hd).transpose(1, 2)
        a = torch.softmax(q @ k.transpose(-1, -2) * (1.0 / hd ** 0.5), -1)
        return s.o((a @ v).transpose(1, 2).reshape(1, -1, D))

class DecLayer(nn.Module):             # couche de décodeur transformer (auto-attention, attention croisée, FF)
    def __init__(s, d, h, ff):
        super().__init__(); s.sa = MHA(d, h); s.ca = MHA(d, h); s.f1 = nn.Linear(d, ff); s.f2 = nn.Linear(ff, d)
        s.n1 = nn.LayerNorm(d); s.n2 = nn.LayerNorm(d); s.n3 = nn.LayerNorm(d)
    def forward(s, x, mem):
        x = s.n1(x + s.sa(x, x)); x = s.n2(x + s.ca(x, mem)); return s.n3(x + s.f2(torch.relu(s.f1(x))))

class Proxy(nn.Module):
    def __init__(s):
        super().__init__()
        s.pre = nn.Sequential(nn.Conv1d(1, 32, 9), nn.PReLU(), nn.Conv1d(32, 32, 9), nn.PReLU(), nn.Conv1d(32, 1, 9))
        s.inc = nn.Conv1d(1, ENC, 3 * L, stride=L)
        s.enc = nn.ModuleList([DSConv(ENC, 2 ** i) for i in range(NENC)])
        s.proj = nn.Linear(ENC, DEC)
        s.dec = DecLayer(DEC, 8, 2 * DEC)
        s.mask = nn.Linear(DEC, ENC)
        s.outc = nn.ConvTranspose1d(ENC, 1, 3 * L, stride=L)
    def forward(s, x, st):
        pre_buf, in_buf, bufs, ctx = st
        xx = torch.cat([pre_buf, x], -1); pre_buf = xx[..., -24:]
        x = x + s.pre(xx)
        xx = torch.cat([in_buf, x], -1); in_buf = xx[..., -2 * L:]
        e = s.inc(xx); nbufs = []
        h = e
        for l, b in zip(s.enc, bufs): h, nb = l(h, b); nbufs.append(nb)
        q = s.proj(h.transpose(1, 2))
        mem = torch.cat([ctx, q], 1); ctx = mem[:, -CTX:]
        d = s.dec(q, mem)
        m = torch.sigmoid(s.mask(d)).transpose(1, 2)
        return s.outc(e * m), (pre_buf, in_buf, nbufs, ctx)

def init_state(m):
    return (torch.zeros(1, 1, 24), torch.zeros(1, 1, 2 * L), [torch.zeros(1, ENC, 2 * 2 ** i) for i in range(NENC)], torch.zeros(1, CTX, DEC))

m = Proxy().eval()
macs = [0]
def hook(mod, inp, out):
    if isinstance(mod, nn.Conv1d): macs[0] += out.numel() * mod.in_channels // mod.groups * mod.kernel_size[0]
    elif isinstance(mod, nn.ConvTranspose1d): macs[0] += inp[0].numel() * mod.out_channels * mod.kernel_size[0]
    elif isinstance(mod, nn.Linear): macs[0] += out.numel() * mod.in_features
for mod in m.modules(): mod.register_forward_hook(hook)
params = sum(p.numel() for p in m.parameters())
chunk = torch.randn(1, 1, CH * L)
with torch.inference_mode():
    st = init_state(m); y, st = m(chunk, st)
    macs_lin = macs[0]
    # attention (QK^T et AV) : non comptée par les hooks
    att = 2 * (CH * CTX * DEC) * 2
    per_chunk = macs_lin + att
    for mod in m.modules(): mod._forward_hooks.clear()
    for _ in range(50): y, st = m(chunk, st)
    N = 600; t = time.perf_counter()
    for _ in range(N): y, st = m(chunk, st)
    dt = (time.perf_counter() - t) / N
# capacité brute de ce processeur (1 cœur) sur des multiplications de matrices
a = torch.randn(256, 512); b = torch.randn(512, 512)
for _ in range(20): a @ b
t = time.perf_counter(); R = 400
for _ in range(R): a @ b
peak = 2 * 256 * 512 * 512 * R / (time.perf_counter() - t) / 1e9
chunk_s = CH * L / 16000
gflops_s = 2 * per_chunk / chunk_s / 1e9
print(f"paramètres : {params/1e6:.2f} M")
print(f"calcul : {per_chunk/1e6:.2f} M MAC par morceau de {chunk_s*1000:.0f} ms -> {gflops_s:.2f} GFLOP/s requis en continu")
print(f"ce PC (1 cœur) : {dt*1000:.2f} ms par morceau -> facteur temps réel {dt/chunk_s:.3f} ; débit utile {2*per_chunk/dt/1e9:.1f} GFLOP/s ; pic matmul {peak:.1f} GFLOP/s")
