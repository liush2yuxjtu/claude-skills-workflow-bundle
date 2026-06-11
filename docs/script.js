// === 墨格 Ink Grid — script.js ===
// 极轻量,无依赖,纯 vanilla。

(() => {
  'use strict';

  // 1. Copy-to-clipboard for code blocks
  document.querySelectorAll('[data-copy]').forEach((btn) => {
    btn.addEventListener('click', async () => {
      const code = btn.parentElement.querySelector('code');
      if (!code) return;
      const text = code.innerText;
      try {
        await navigator.clipboard.writeText(text);
        const original = btn.textContent;
        btn.classList.add('copied');
        btn.textContent = '✓ copied';
        setTimeout(() => {
          btn.classList.remove('copied');
          btn.textContent = original;
        }, 1600);
      } catch (e) {
        btn.textContent = '✗ failed';
        setTimeout(() => (btn.textContent = 'copy'), 1600);
      }
    });
  });

  // 2. Reveal on scroll
  if ('IntersectionObserver' in window) {
    const io = new IntersectionObserver(
      (entries) => {
        entries.forEach((e) => {
          if (e.isIntersecting) {
            e.target.classList.add('in');
            io.unobserve(e.target);
          }
        });
      },
      { threshold: 0.12, rootMargin: '0px 0px -8% 0px' }
    );
    document
      .querySelectorAll('.sec, .skill, .beat, .verify-grid > div')
      .forEach((el) => io.observe(el));
  } else {
    // 退化路径:一次性全部显示
    document
      .querySelectorAll('.sec, .skill, .beat, .verify-grid > div')
      .forEach((el) => el.classList.add('in'));
  }

  // 3. Subtle parallax on hero seal (desktop only)
  const seal = document.getElementById('seal');
  const isDesktop = window.matchMedia('(min-width: 981px)').matches;
  if (seal && isDesktop && !window.matchMedia('(prefers-reduced-motion: reduce)').matches) {
    let ticking = false;
    window.addEventListener(
      'scroll',
      () => {
        if (!ticking) {
          window.requestAnimationFrame(() => {
            const y = Math.min(window.scrollY, 600);
            seal.style.transform = `rotate(-4deg) translateY(${y * -0.08}px)`;
            ticking = false;
          });
          ticking = true;
        }
      },
      { passive: true }
    );
  }

  // 4. Hero 印章 ink-spread on click — small easter egg
  if (seal) {
    seal.addEventListener('click', () => {
      seal.style.animation = 'none';
      // 强制 reflow
      // eslint-disable-next-line no-unused-expressions
      seal.offsetHeight;
      seal.style.animation = 'seal-drop 0.8s cubic-bezier(0.18, 0.7, 0.2, 1) forwards';
    });
  }
})();
