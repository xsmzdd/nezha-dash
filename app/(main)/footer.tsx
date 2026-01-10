"use client"

import { useEffect, useState } from "react"

/* =======================
   链接配置（统一管理）
======================= */
const TG_URL = "https://t.me/VPS_zm"
const QQ_URL = "https://qm.qq.com/cgi-bin/qm/qr?k=413959134" // ← 你可替换
const SITE_URL = "https://xn--gmqv8g4v8e0wd.top" // ← 你可替换

/* =======================
   通用样式
======================= */
const baseTextStyles =
  "text-[13px] font-light tracking-tight text-neutral-600/60 dark:text-neutral-300/60"

/* =======================
   Footer Link
======================= */
type LinkProps = {
  href: string
  children: React.ReactNode
}

const FooterLink = ({ href, children }: LinkProps) => (
  <a
    href={href}
    target="_blank"
    rel="noreferrer"
    className="inline-flex items-center gap-1 transition-opacity hover:opacity-80"
  >
    {children}
  </a>
)

/* =======================
   图标组件（SVG 内联）
======================= */
const TelegramIcon = () => (
  <svg viewBox="0 0 24 24" className="h-4 w-4 fill-current">
    <path d="M9.036 15.548 8.84 19.03c.28 0 .4-.12.544-.264l1.308-1.256 2.712 1.98c.496.276.848.132.972-.456l1.76-8.264c.152-.708-.256-.984-.736-.804L4.6 11.6c-.68.264-.668.648-.124.816l2.772.864 6.432-4.056c.304-.184.58-.084.352.116" />
  </svg>
)

const QQIcon = () => (
  <svg viewBox="0 0 1024 1024" className="h-4 w-4 fill-current">
    <path d="M512 64C282 64 96 250 96 480c0 174 106 322 258 384-6-30-10-62-10-96 0-168 336-168 336 0 0 34-4 66-10 96 152-62 258-210 258-384C928 250 742 64 512 64z" />
  </svg>
)

const GlobeIcon = () => (
  <svg viewBox="0 0 24 24" className="h-4 w-4 fill-current">
    <path d="M12 2a10 10 0 100 20 10 10 0 000-20zm6.93 9h-3.02a15.6 15.6 0 00-1.3-5.01A8.03 8.03 0 0118.93 11zM12 4.07c.83 1.2 1.48 2.93 1.83 4.93H10.17c.35-2 .99-3.73 1.83-4.93zM5.07 13h3.02c.3 1.78.88 3.43 1.7 4.77A8.03 8.03 0 015.07 13zm3.02-2H5.07a8.03 8.03 0 014.72-5.01A15.6 15.6 0 008.09 11zm2.08 2h3.66c-.35 2-.99 3.73-1.83 4.93-.84-1.2-1.48-2.93-1.83-4.93zm4.74 4.77c.82-1.34 1.4-2.99 1.7-4.77h3.02a8.03 8.03 0 01-4.72 4.77z" />
  </svg>
)

/* =======================
   Footer 主组件
======================= */
export default function Footer() {
  const currentYear = new Date().getFullYear()
  const [isMac, setIsMac] = useState(true)

  useEffect(() => {
    setIsMac(/macintosh|mac os x/i.test(navigator.userAgent))
  }, [])

  return (
    <footer className="mx-auto flex w-full max-w-5xl items-center justify-between">
      <section className="flex flex-col gap-1">
        {/* 渐变标题 */}
        <h2 className="text-[14px] font-semibold tracking-wide bg-gradient-to-r from-yellow-400 via-orange-400 to-red-500 bg-clip-text text-transparent">
          加钱道人全球监控面板
        </h2>

        {/* 版权 + 图标组 */}
        <div className={`flex items-center gap-3 ${baseTextStyles}`}>
          <span>© 2020–{currentYear}</span>

          <FooterLink href={TG_URL}>
            <TelegramIcon />
            <span>@VPSzm</span>
          </FooterLink>

          <FooterLink href={QQ_URL}>
            <QQIcon />
            <span>QQ</span>
          </FooterLink>

          <FooterLink href={SITE_URL}>
            <GlobeIcon />
            <span>官网</span>
          </FooterLink>
        </div>
      </section>

      {/* 快捷键提示 */}
      <kbd className="pointer-events-none inline-flex h-4 select-none items-center gap-1 rounded border bg-muted px-1.5 font-mono text-[10px] text-muted-foreground">
        {isMac ? <span className="text-xs">⌘</span> : "Ctrl "}K
      </kbd>
    </footer>
  )
}
