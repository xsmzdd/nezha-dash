"use client"

import countries from "i18n-iso-countries"
import enLocale from "i18n-iso-countries/langs/en.json"
import { notFound, useRouter } from "next/navigation"
import { useTranslations } from "next-intl"
import { useEffect, useState } from "react"
import { useServerData } from "@/app/context/server-data-context"
import CountryFlagBackdrop from "@/components/CountryFlagBackdrop"
import { BackIcon } from "@/components/Icon"
import { ServerDetailLoading } from "@/components/loading/ServerDetailLoading"
import ServerFlag from "@/components/ServerFlag"
import { Badge } from "@/components/ui/badge"
import { Card, CardContent } from "@/components/ui/card"
import {
  cn,
  convertEmojiToCountryCode,
  formatBytes,
  formatNezhaInfo,
  isEmojiFlag,
} from "@/lib/utils"

countries.registerLocale(enLocale)

const detailGlassCardClass =
  "dark:!border dark:!border-white/10 dark:!bg-white/10 dark:!shadow-lg dark:!shadow-black/20 dark:!ring-white/10 dark:!backdrop-blur-md"

// Function to get country name, handling both country codes and emoji flags
function getCountryDisplayName(countryCode: string): string {
  if (isEmojiFlag(countryCode)) {
    // Convert emoji to country code for name lookup
    const convertedCode = convertEmojiToCountryCode(countryCode)
    if (convertedCode) {
      return countries.getName(convertedCode, "en") || ""
    }
    return ""
  }
  return countries.getName(countryCode, "en") || ""
}

export default function ServerDetailClient({ server_id }: { server_id: number }) {
  const t = useTranslations("ServerDetailClient")
  const router = useRouter()

  const [hasHistory, setHasHistory] = useState(false)

  useEffect(() => {
    window.scrollTo({ top: 0, left: 0, behavior: "instant" })
  }, [])

  useEffect(() => {
    const previousPath = sessionStorage.getItem("fromMainPage")
    if (previousPath) {
      setHasHistory(true)
    }
  }, [])

  const linkClick = () => {
    if (hasHistory) {
      router.back()
    } else {
      router.push("/")
    }
  }

  const { data: serverList, error, isLoading } = useServerData()
  const serverData = serverList?.result?.find((item) => item.id === server_id)

  if (!serverData && !isLoading) {
    notFound()
  }

  if (error) {
    return (
      <div className="flex flex-col items-center justify-center">
        <p className="font-medium text-sm opacity-40">{error.message}</p>
        <p className="font-medium text-sm opacity-40">{t("detail_fetch_error_message")}</p>
      </div>
    )
  }

  if (!serverData) return <ServerDetailLoading />

  const {
    name,
    online,
    uptime,
    version,
    arch,
    mem_total,
    disk_total,
    country_code,
    platform,
    platform_version,
    cpu_info,
    gpu_info,
    load_1,
    load_5,
    load_15,
    net_out_transfer,
    net_in_transfer,
    last_active_time_string,
    boot_time_string,
  } = formatNezhaInfo(serverData)

  return (
    <div>
      <div
        onClick={linkClick}
        className="flex flex-none cursor-pointer items-center gap-1.5 break-all font-semibold text-3xl leading-tight tracking-tight transition-opacity duration-300 hover:opacity-50"
      >
        <BackIcon />
        {name}
      </div>
      <div className="relative mt-5 overflow-hidden rounded-2xl">
        <CountryFlagBackdrop country_code={country_code} direction="horizontal" />
        <section className="relative z-10 flex flex-wrap gap-4">
        <Card className={cn("border-none bg-transparent shadow-none ring-0", detailGlassCardClass)}>
          <CardContent className="px-3 py-2">
            <section className="flex flex-col items-start gap-1.5">
              <p className="text-muted-foreground text-lg">{t("status")}</p>
              <Badge
                className={cn(
                  "-mt-[0.3px] w-fit rounded-[6px] px-2 py-0.5 text-[14px] dark:text-white",
                  {
                    "bg-green-800": online,
                    "bg-red-600": !online,
                  },
                )}
              >
                {online ? t("Online") : t("Offline")}
              </Badge>
            </section>
          </CardContent>
        </Card>
        <Card className={cn("border-none bg-transparent shadow-none ring-0", detailGlassCardClass)}>
          <CardContent className="px-3 py-2">
            <section className="flex flex-col items-start gap-1.5">
              <p className="text-muted-foreground text-lg">{t("Uptime")}</p>
              <div className="text-lg">
                {" "}
                {uptime / 86400 >= 1
                  ? `${Math.floor(uptime / 86400)} ${t("Days")} ${Math.floor((uptime % 86400) / 3600)} ${t("Hours")}`
                  : `${Math.floor(uptime / 3600)} ${t("Hours")}`}
              </div>
            </section>
          </CardContent>
        </Card>
        {version && (
          <Card className={cn("border-none bg-transparent shadow-none ring-0", detailGlassCardClass)}>
            <CardContent className="px-3 py-2">
              <section className="flex flex-col items-start gap-1.5">
                <p className="text-muted-foreground text-lg">{t("Version")}</p>
                <div className="text-lg">{version} </div>
              </section>
            </CardContent>
          </Card>
        )}
        {arch && (
          <Card className={cn("border-none bg-transparent shadow-none ring-0", detailGlassCardClass)}>
            <CardContent className="px-3 py-2">
              <section className="flex flex-col items-start gap-1.5">
                <p className="text-muted-foreground text-lg">{t("Arch")}</p>
                <div className="text-lg">{arch} </div>
              </section>
            </CardContent>
          </Card>
        )}

        <Card className={cn("border-none bg-transparent shadow-none ring-0", detailGlassCardClass)}>
          <CardContent className="px-3 py-2">
            <section className="flex flex-col items-start gap-1.5">
              <p className="text-muted-foreground text-lg">{t("Mem")}</p>
              <div className="text-lg">{formatBytes(mem_total)}</div>
            </section>
          </CardContent>
        </Card>
        <Card className={cn("border-none bg-transparent shadow-none ring-0", detailGlassCardClass)}>
          <CardContent className="px-3 py-2">
            <section className="flex flex-col items-start gap-1.5">
              <p className="text-muted-foreground text-lg">{t("Disk")}</p>
              <div className="text-lg">{formatBytes(disk_total)}</div>
            </section>
          </CardContent>
        </Card>
        {country_code && (
          <Card className={cn("border-none bg-transparent shadow-none ring-0", detailGlassCardClass)}>
            <CardContent className="px-3 py-2">
              <section className="flex flex-col items-start gap-1.5">
                <p className="text-muted-foreground text-lg">{t("Region")}</p>
                <section className="flex items-start gap-1">
                  {getCountryDisplayName(country_code) && (
                    <div className="text-start text-lg">{getCountryDisplayName(country_code)}</div>
                  )}
                  <ServerFlag className="-mt-px text-[16px]" country_code={country_code} />
                </section>
              </section>
            </CardContent>
          </Card>
        )}
      </section>
      <section className="mt-4 flex flex-wrap gap-4">
        {platform && (
          <Card className={cn("border-none bg-transparent shadow-none ring-0", detailGlassCardClass)}>
            <CardContent className="px-3 py-2">
              <section className="flex flex-col items-start gap-1.5">
                <p className="text-muted-foreground text-lg">{t("System")}</p>

                <div className="text-lg">
                  {" "}
                  {platform} - {platform_version}{" "}
                </div>
              </section>
            </CardContent>
          </Card>
        )}
        {cpu_info && cpu_info.length > 0 && (
          <Card className={cn("border-none bg-transparent shadow-none ring-0", detailGlassCardClass)}>
            <CardContent className="px-3 py-2">
              <section className="flex flex-col items-start gap-1.5">
                <p className="text-muted-foreground text-lg">{t("CPU")}</p>

                <div className="text-lg"> {cpu_info.join(", ")}</div>
              </section>
            </CardContent>
          </Card>
        )}
        {gpu_info && gpu_info.length > 0 && (
          <Card className={cn("border-none bg-transparent shadow-none ring-0", detailGlassCardClass)}>
            <CardContent className="px-3 py-2">
              <section className="flex flex-col items-start gap-1.5">
                <p className="text-muted-foreground text-lg">{"GPU"}</p>
                <div className="text-lg"> {gpu_info.join(", ")}</div>
              </section>
            </CardContent>
          </Card>
        )}
      </section>
      <section className="mt-4 flex flex-wrap gap-4">
        <Card className={cn("border-none bg-transparent shadow-none ring-0", detailGlassCardClass)}>
          <CardContent className="px-3 py-2">
            <section className="flex flex-col items-start gap-1.5">
              <p className="text-muted-foreground text-lg">{t("Load")}</p>
              <div className="text-lg">
                {load_1 || "0.00"} / {load_5 || "0.00"} / {load_15 || "0.00"}
              </div>
            </section>
          </CardContent>
        </Card>
        <Card className={cn("border-none bg-transparent shadow-none ring-0", detailGlassCardClass)}>
          <CardContent className="px-3 py-2">
            <section className="flex flex-col items-start gap-1.5">
              <p className="text-muted-foreground text-lg">{t("Upload")}</p>
              {net_out_transfer ? (
                <div className="text-lg"> {formatBytes(net_out_transfer)} </div>
              ) : (
                <div className="text-lg">Unknown</div>
              )}
            </section>
          </CardContent>
        </Card>
        <Card className={cn("border-none bg-transparent shadow-none ring-0", detailGlassCardClass)}>
          <CardContent className="px-3 py-2">
            <section className="flex flex-col items-start gap-1.5">
              <p className="text-muted-foreground text-lg">{t("Download")}</p>
              {net_in_transfer ? (
                <div className="text-lg"> {formatBytes(net_in_transfer)} </div>
              ) : (
                <div className="text-lg">Unknown</div>
              )}
            </section>
          </CardContent>
        </Card>
      </section>
      <section className="mt-4 flex flex-wrap gap-4">
        <Card className={cn("border-none bg-transparent shadow-none ring-0", detailGlassCardClass)}>
          <CardContent className="px-3 py-2">
            <section className="flex flex-col items-start gap-1.5">
              <p className="text-muted-foreground text-lg">{t("BootTime")}</p>
              <div className="text-lg">{boot_time_string ? boot_time_string : "N/A"}</div>
            </section>
          </CardContent>
        </Card>
        <Card className={cn("border-none bg-transparent shadow-none ring-0", detailGlassCardClass)}>
          <CardContent className="px-3 py-2">
            <section className="flex flex-col items-start gap-1.5">
              <p className="text-muted-foreground text-lg">{t("LastActive")}</p>
              <div className="text-lg">
                {last_active_time_string ? last_active_time_string : "N/A"}
              </div>
            </section>
          </CardContent>
        </Card>
      </section>
      </div>
    </div>
  )
}
