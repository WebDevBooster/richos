//! A radix-2 complex FFT — the only piece of maths the echo canceller needs, hand-rolled.
//!
//! ## Why hand-rolled rather than a crate
//!
//! `richos-voice` ships with exactly one third-party native dependency (`cpal`). RichOS is
//! going to be open-sourced and `wiki/open-source-strategy.md` treats the license of every
//! vendored artefact as a v1 gate, so the cheapest license is the one we do not have to
//! audit. This file is ~120 lines of textbook Cooley–Tukey; pulling in `rustfft` (and its
//! `num-complex`/`num-traits`/`primal-check`/`strength_reduce` tail) to get it would trade
//! that for four more licenses to name and four more crates to vendor into a signed bundle.
//!
//! It is also the *right* size. The canceller uses ONE transform length — 512 — so the
//! twiddle factors and the bit-reversal permutation are computed once at construction and
//! the hot path is a plain in-place butterfly loop with no allocation whatsoever. That
//! matters: this runs on the capture callback thread, where an allocation is a click.
//!
//! Correctness is not asserted, it is tested: round-trip identity, a known DFT of a unit
//! impulse and of a pure bin, Parseval's theorem, and — the one that actually guards the
//! canceller — **circular convolution via the frequency domain agrees with the direct
//! time-domain convolution to 1e-4**. That last test is the contract `aec.rs` depends on.

/// A complex number. Deliberately concrete `f32` and `Copy`: this type appears in the
/// canceller's hot loops and must never become a trait object or an allocation.
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct C {
    pub re: f32,
    pub im: f32,
}

impl C {
    pub const ZERO: C = C { re: 0.0, im: 0.0 };

    pub fn new(re: f32, im: f32) -> C {
        C { re, im }
    }

    /// Complex multiply.
    #[inline(always)]
    pub fn mul(self, o: C) -> C {
        C { re: self.re * o.re - self.im * o.im, im: self.re * o.im + self.im * o.re }
    }

    /// `self * conj(o)` — the correlation the adaptive filter's gradient is built from.
    /// Written out rather than composed from `conj()` + `mul()` so the hot loop does six
    /// flops, not eight.
    #[inline(always)]
    pub fn mul_conj(self, o: C) -> C {
        C { re: self.re * o.re + self.im * o.im, im: self.im * o.re - self.re * o.im }
    }

    #[inline(always)]
    pub fn add(self, o: C) -> C {
        C { re: self.re + o.re, im: self.im + o.im }
    }

    #[inline(always)]
    pub fn sub(self, o: C) -> C {
        C { re: self.re - o.re, im: self.im - o.im }
    }

    #[inline(always)]
    pub fn scale(self, k: f32) -> C {
        C { re: self.re * k, im: self.im * k }
    }

    /// Squared magnitude. No `sqrt` — every use in the canceller is a power, not a level.
    #[inline(always)]
    pub fn norm_sq(self) -> f32 {
        self.re * self.re + self.im * self.im
    }
}

/// A fixed-length radix-2 FFT. Build once, transform many times, allocate never.
#[derive(Debug, Clone)]
pub struct Fft {
    n: usize,
    /// Bit-reversal permutation, precomputed.
    rev: Vec<u32>,
    /// Forward twiddles, laid out stage by stage: `e^{-2*pi*i*k/len}`.
    tw_fwd: Vec<C>,
    /// Inverse twiddles: the conjugates.
    tw_inv: Vec<C>,
}

impl Fft {
    /// `n` must be a power of two and at least 2.
    pub fn new(n: usize) -> Fft {
        assert!(n >= 2 && n.is_power_of_two(), "FFT length must be a power of two >= 2, got {n}");
        let bits = n.trailing_zeros();
        let rev: Vec<u32> = (0..n).map(|i| (i as u32).reverse_bits() >> (32 - bits)).collect();

        // One contiguous twiddle table. Stage with half-length `h` reads `tw[h + k]`, so the
        // table is indexed by (half-length, k) with no per-stage bookkeeping in the hot loop.
        let mut tw_fwd = vec![C::ZERO; n];
        let mut tw_inv = vec![C::ZERO; n];
        let mut h = 1usize;
        while h < n {
            for k in 0..h {
                let ang = -std::f64::consts::PI * (k as f64) / (h as f64);
                let (s, c) = ang.sin_cos();
                tw_fwd[h + k] = C::new(c as f32, s as f32);
                tw_inv[h + k] = C::new(c as f32, -(s as f32));
            }
            h <<= 1;
        }
        Fft { n, rev, tw_fwd, tw_inv }
    }

    pub fn len(&self) -> usize {
        self.n
    }

    pub fn is_empty(&self) -> bool {
        false
    }

    /// In-place forward transform. `buf.len()` must equal [`Fft::len`].
    pub fn forward(&self, buf: &mut [C]) {
        self.run(buf, &self.tw_fwd, false);
    }

    /// In-place inverse transform, normalised by `1/n` so `inverse(forward(x)) == x`.
    pub fn inverse(&self, buf: &mut [C]) {
        self.run(buf, &self.tw_inv, true);
    }

    fn run(&self, buf: &mut [C], tw: &[C], normalise: bool) {
        assert_eq!(buf.len(), self.n, "FFT buffer length mismatch");
        // Decimation-in-time: permute, then butterfly upward.
        for i in 0..self.n {
            let j = self.rev[i] as usize;
            if j > i {
                buf.swap(i, j);
            }
        }
        let mut h = 1usize;
        while h < self.n {
            let step = h << 1;
            let mut base = 0usize;
            while base < self.n {
                for k in 0..h {
                    let w = tw[h + k];
                    let a = buf[base + k];
                    let b = buf[base + k + h].mul(w);
                    buf[base + k] = a.add(b);
                    buf[base + k + h] = a.sub(b);
                }
                base += step;
            }
            h = step;
        }
        if normalise {
            let k = 1.0 / self.n as f32;
            for v in buf.iter_mut() {
                *v = v.scale(k);
            }
        }
    }

    /// Load real samples into a complex buffer, zeroing the imaginary part. Convenience for
    /// the canceller, which only ever transforms real signals.
    pub fn load_real(&self, src: &[f32], dst: &mut [C]) {
        assert_eq!(dst.len(), self.n);
        for (d, s) in dst.iter_mut().zip(src.iter()) {
            *d = C::new(*s, 0.0);
        }
        for d in dst.iter_mut().skip(src.len()) {
            *d = C::ZERO;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn approx(a: f32, b: f32, tol: f32, what: &str) {
        assert!((a - b).abs() <= tol, "{what}: {a} vs {b} (tol {tol})");
    }

    /// INVARIANT: the inverse transform undoes the forward transform. If this drifts, every
    /// ERLE figure the canceller reports is fiction.
    #[test]
    fn forward_then_inverse_returns_the_original_signal() {
        let fft = Fft::new(512);
        let src: Vec<f32> = (0..512)
            .map(|i| (i as f32 * 0.37).sin() * 0.6 + (i as f32 * 0.011).cos() * 0.2)
            .collect();
        let mut buf = vec![C::ZERO; 512];
        fft.load_real(&src, &mut buf);
        fft.forward(&mut buf);
        fft.inverse(&mut buf);
        for (i, (got, want)) in buf.iter().zip(src.iter()).enumerate() {
            approx(got.re, *want, 1e-4, &format!("re[{i}]"));
            approx(got.im, 0.0, 1e-4, &format!("im[{i}]"));
        }
    }

    /// INVARIANT: the DFT of a unit impulse is flat unity across every bin — the standard
    /// smoke test that the twiddles and the bit-reversal agree with each other.
    #[test]
    fn the_transform_of_an_impulse_is_flat() {
        let fft = Fft::new(64);
        let mut buf = vec![C::ZERO; 64];
        buf[0] = C::new(1.0, 0.0);
        fft.forward(&mut buf);
        for (k, v) in buf.iter().enumerate() {
            approx(v.re, 1.0, 1e-5, &format!("bin {k} re"));
            approx(v.im, 0.0, 1e-5, &format!("bin {k} im"));
        }
    }

    /// INVARIANT: a pure sinusoid at exactly bin 5 puts all its energy in bins 5 and n-5 and
    /// nowhere else. Catches an off-by-one in the twiddle sign or the stage indexing.
    #[test]
    fn a_pure_bin_lands_in_exactly_that_bin() {
        let n = 64;
        let fft = Fft::new(n);
        let src: Vec<f32> =
            (0..n).map(|i| (2.0 * std::f32::consts::PI * 5.0 * i as f32 / n as f32).cos()).collect();
        let mut buf = vec![C::ZERO; n];
        fft.load_real(&src, &mut buf);
        fft.forward(&mut buf);
        for (k, v) in buf.iter().enumerate() {
            let mag = v.norm_sq().sqrt();
            if k == 5 || k == n - 5 {
                approx(mag, n as f32 / 2.0, 1e-3, &format!("bin {k}"));
            } else {
                assert!(mag < 1e-3, "energy leaked into bin {k}: {mag}");
            }
        }
    }

    /// INVARIANT: Parseval — energy is conserved. sum|x|^2 == (1/n) sum|X|^2.
    #[test]
    fn parseval_energy_is_conserved() {
        let n = 256;
        let fft = Fft::new(n);
        let src: Vec<f32> = (0..n).map(|i| ((i * 7919) % 101) as f32 / 101.0 - 0.5).collect();
        let time_energy: f32 = src.iter().map(|s| s * s).sum();
        let mut buf = vec![C::ZERO; n];
        fft.load_real(&src, &mut buf);
        fft.forward(&mut buf);
        let freq_energy: f32 = buf.iter().map(|c| c.norm_sq()).sum::<f32>() / n as f32;
        approx(freq_energy, time_energy, time_energy * 1e-4, "parseval");
    }

    /// **THE CONTRACT `aec.rs` RESTS ON.** Multiplying two spectra and inverting gives the
    /// CIRCULAR convolution of the two signals. The canceller's whole overlap-save structure
    /// assumes this exactly; if it were only approximately true the adaptive filter would
    /// converge to the wrong echo path and every ERLE number would be a lie.
    #[test]
    fn spectral_product_is_circular_convolution() {
        let n = 32;
        let fft = Fft::new(n);
        let a: Vec<f32> = (0..n).map(|i| ((i * 13) % 7) as f32 - 3.0).collect();
        let mut b = vec![0.0f32; n];
        b[0] = 1.0;
        b[3] = -0.5;
        b[9] = 0.25; // a short "impulse response"

        // Direct circular convolution, the definition.
        let mut want = vec![0.0f32; n];
        for (i, w) in want.iter_mut().enumerate() {
            let mut acc = 0.0;
            for (j, bj) in b.iter().enumerate() {
                acc += a[(i + n - j) % n] * bj;
            }
            *w = acc;
        }

        let mut fa = vec![C::ZERO; n];
        let mut fb = vec![C::ZERO; n];
        fft.load_real(&a, &mut fa);
        fft.load_real(&b, &mut fb);
        fft.forward(&mut fa);
        fft.forward(&mut fb);
        for (x, y) in fa.iter_mut().zip(fb.iter()) {
            *x = x.mul(*y);
        }
        fft.inverse(&mut fa);
        for i in 0..n {
            approx(fa[i].re, want[i], 1e-4, &format!("conv[{i}]"));
        }
    }

    /// INVARIANT: `mul_conj(a, b) == a * conj(b)`, the gradient correlation. Hand-unrolled
    /// for speed, so it gets its own test rather than being trusted.
    #[test]
    fn mul_conj_is_multiplication_by_the_conjugate() {
        let a = C::new(2.0, -3.0);
        let b = C::new(-1.5, 0.75);
        let want = a.mul(C::new(b.re, -b.im));
        let got = a.mul_conj(b);
        approx(got.re, want.re, 1e-6, "re");
        approx(got.im, want.im, 1e-6, "im");
    }

    /// INVARIANT: `load_real` zero-pads a short source — the overlap-save gradient block
    /// depends on the second half being exactly zero, not merely small.
    #[test]
    fn load_real_zero_pads_a_short_source() {
        let fft = Fft::new(8);
        let mut buf = vec![C::new(9.9, 9.9); 8];
        fft.load_real(&[1.0, 2.0, 3.0], &mut buf);
        assert_eq!(buf[0], C::new(1.0, 0.0));
        assert_eq!(buf[2], C::new(3.0, 0.0));
        for b in buf.iter().skip(3) {
            assert_eq!(*b, C::ZERO, "zero-padding is not exact");
        }
    }
}
