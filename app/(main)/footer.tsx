"use client"

import { useTranslations } from "next-intl"
import { useEffect, useState } from "react"
import pack from "@/package.json"

const GITHUB_URL = "https://github.com/hamster1963/nezha-dash"
const PERSONAL_URL = "https://buycoffee.top"

type LinkProps = {
  href: string
  children: React.ReactNode
}

const FooterLink = ({ href, children }: LinkProps) => (
  <a
    href={href}
    target="_blank"
    className="cursor-pointer font-normal underline decoration-2 decoration-yellow-500 underline-offset-2 transition-colors hover:decoration-yellow-600 dark:decoration-yellow-500/60 dark:hover:decoration-yellow-500/80"
    rel="noreferrer"
  >
    {children}
  </a>
)

const baseTextStyles =
  "text-[13px] font-light tracking-tight text-neutral-600/50 dark:text-neutral-300/50"

export default function Footer() {
  const t = useTranslations("Footer")
  const version = pack.version
  const currentYear = new Date().getFullYear()
  const [isMac, setIsMac] = useState(true)

  useEffect(() => {
    setIsMac(/macintosh|mac os x/i.test(navigator.userAgent))
  }, [])

return (
  <footer className="mx-auto flex w-full max-w-5xl items-center justify-between">
    <section className="flex flex-col">
      {/* 第一行：标题 */}
      <p className={`mt-3 ${baseTextStyles}`}>
        加钱道人全球监控面板
      </p>

      {/* 第二行：版权 + TG */}
      <section className={`mt-1 flex items-center gap-2 ${baseTextStyles}`}>
        © 2020-{currentYear}
        <span>联系TG:</span>
        <FooterLink href="https://t.me/VPS_zm">@VPSzm</FooterLink>
      </section>
    </section>

    {/* 右侧快捷键保持不变 */}
    <p className={`mt-1 ${baseTextStyles}`}>
      <kbd className="pointer-events-none mx-1 inline-flex h-4 select-none items-center gap-1 rounded border bg-muted px-1.5 font-medium font-mono text-[10px] text-muted-foreground opacity-100">
        {isMac ? <span className="text-xs">⌘</span> : "Ctrl "}K
      </kbd>
    </p>
  </footer>
)
}
