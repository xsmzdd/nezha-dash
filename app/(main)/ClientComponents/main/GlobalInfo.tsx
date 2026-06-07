"use client"

import { useTranslations } from "next-intl"

type GlobalInfoProps = {
  countries: string[]
  undistributedCount?: number
}

export default function GlobalInfo({ countries, undistributedCount = 0 }: GlobalInfoProps) {
  const t = useTranslations("Global")

  return (
    <section className="flex items-center justify-between pl-1">
      <p className="font-medium text-sm opacity-60 md:text-[15px]">
        {t("Distributions")} {countries.length} {t("Regions")}
        <span className="ml-3">服务器未分布 {undistributedCount} 个地区</span>
      </p>
    </section>
  )
}
