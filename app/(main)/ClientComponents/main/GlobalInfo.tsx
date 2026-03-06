"use client"

import { useTranslations } from "next-intl"

type GlobalInfoProps = {
  countries: string[]
}

export default function GlobalInfo({ countries }: GlobalInfoProps) {
  const t = useTranslations("Global")

  return (
    <section className="flex items-center justify-between pl-1">
      <p className="font-medium text-sm opacity-60 md:text-[15px]">
        {t("Distributions")} {countries.length} {t("Regions")}
      </p>
    </section>
  )
}
