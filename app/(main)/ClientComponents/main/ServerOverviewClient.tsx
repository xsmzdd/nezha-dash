"use client"

import Image from "next/image"
import { useTranslations } from "next-intl"
import { useEffect, useMemo, useState, type ReactNode } from "react"
import { useFilter } from "@/app/context/network-filter-context"
import { useServerData } from "@/app/context/server-data-context"
import { useStatus } from "@/app/context/status-context"
import AnimateCountClient from "@/components/AnimatedCount"
import { Loader } from "@/components/loading/Loader"
import { Card, CardContent } from "@/components/ui/card"
import getEnv from "@/lib/env-entry"
import { cn, formatBytes } from "@/lib/utils"
import blogMan from "@/public/blog-man.webp"

const speedChartPercent = (speed: number) => {
  if (!speed || speed <= 0) return 0
  const mib = speed / 1024 / 1024
  return Math.min(100, Math.max(3, Math.log10(mib + 1) * 42))
}

const buildAreaPath = (values: number[], width: number, height: number) => {
  const paddedValues = values.length > 1 ? values : [0, values[0] ?? 0]
  const maxValue = Math.max(...paddedValues, 1)
  const points = paddedValues.map((value, index) => {
    const x = (index / (paddedValues.length - 1)) * width
    const y = height - (value / maxValue) * (height * 0.76) - height * 0.12
    return { x, y }
  })

  const linePath = points.reduce((path, point, index) => {
    if (index === 0) return `M ${point.x.toFixed(2)} ${point.y.toFixed(2)}`
    const previous = points[index - 1]
    const controlX = (previous.x + point.x) / 2
    return `${path} C ${controlX.toFixed(2)} ${previous.y.toFixed(2)}, ${controlX.toFixed(2)} ${point.y.toFixed(2)}, ${point.x.toFixed(2)} ${point.y.toFixed(2)}`
  }, "")

  const first = points[0]
  const last = points[points.length - 1]
  const areaPath = `${linePath} L ${last.x.toFixed(2)} ${height} L ${first.x.toFixed(2)} ${height} Z`

  return { linePath, areaPath }
}

function CombinedSpeedAreaChart({ uploadSpeed, downloadSpeed }: { uploadSpeed: number; downloadSpeed: number }) {
  const cardT = useTranslations("ServerCard")
  const [uploadHistory, setUploadHistory] = useState<number[]>(() => Array.from({ length: 24 }, () => 0))
  const [downloadHistory, setDownloadHistory] = useState<number[]>(() => Array.from({ length: 24 }, () => 0))
  const uploadPoint = speedChartPercent(uploadSpeed)
  const downloadPoint = speedChartPercent(downloadSpeed)

  useEffect(() => {
    setUploadHistory((previous) => [...previous.slice(-27), uploadPoint])
  }, [uploadPoint])

  useEffect(() => {
    setDownloadHistory((previous) => [...previous.slice(-27), downloadPoint])
  }, [downloadPoint])

  const uploadPath = useMemo(() => buildAreaPath(uploadHistory, 280, 66), [uploadHistory])
  const downloadPath = useMemo(() => buildAreaPath(downloadHistory, 280, 66), [downloadHistory])

  return (
    <section className="flex w-full min-w-0 flex-col gap-3">
      <div className="grid grid-cols-2 gap-4 text-[13px] leading-none">
        <div className="flex min-w-0 items-center gap-2">
          <span className="shrink-0 whitespace-nowrap text-muted-foreground">{cardT("Upload")}</span>
          <span className="min-w-0 whitespace-nowrap font-semibold text-blue-800 tabular-nums dark:text-blue-400">{formatBytes(uploadSpeed)}/s</span>
        </div>
        <div className="flex min-w-0 items-center justify-end gap-2">
          <span className="shrink-0 whitespace-nowrap text-muted-foreground">{cardT("Download")}</span>
          <span className="min-w-0 whitespace-nowrap font-semibold text-purple-800 tabular-nums dark:text-purple-400">{formatBytes(downloadSpeed)}/s</span>
        </div>
      </div>
      <svg className="h-[76px] w-full overflow-visible" viewBox="0 0 280 76" role="img" aria-label={`${cardT("Upload")} ${formatBytes(uploadSpeed)}/s, ${cardT("Download")} ${formatBytes(downloadSpeed)}/s`}>
        <title>{`${cardT("Upload")} ${formatBytes(uploadSpeed)}/s, ${cardT("Download")} ${formatBytes(downloadSpeed)}/s`}</title>
        <defs>
          <linearGradient id="overview-speed-upload" x1="0" x2="0" y1="0" y2="1">
            <stop offset="0%" stopColor="rgba(30,64,175,0.20)" />
            <stop offset="100%" stopColor="rgba(255,255,255,0)" />
          </linearGradient>
          <linearGradient id="overview-speed-download" x1="0" x2="0" y1="0" y2="1">
            <stop offset="0%" stopColor="rgba(107,33,168,0.16)" />
            <stop offset="100%" stopColor="rgba(255,255,255,0)" />
          </linearGradient>
        </defs>
        <line x1="0" x2="280" y1="62" y2="62" stroke="rgba(255,255,255,0.18)" strokeWidth="1" />
        <path d={uploadPath.areaPath} fill="url(#overview-speed-upload)" />
        <path d={downloadPath.areaPath} fill="url(#overview-speed-download)" />
        <path d={uploadPath.linePath} fill="none" stroke="#1e40af" strokeLinecap="round" strokeLinejoin="round" strokeWidth="2.4" />
        <path d={downloadPath.linePath} fill="none" stroke="#6b21a8" strokeLinecap="round" strokeLinejoin="round" strokeWidth="2.4" />
      </svg>
    </section>
  )
}

function CountBlock({ dotClass, children }: { dotClass: string; children: ReactNode }) {
  return (
    <div className="flex min-w-0 items-center gap-2">
      <span className="relative flex h-2 w-2 shrink-0">
        {dotClass.includes("animate") && <span className={cn("absolute inline-flex h-full w-full rounded-full opacity-75", dotClass)} />}
        <span className={cn("relative inline-flex h-2 w-2 rounded-full", dotClass.replace("animate-ping", ""))} />
      </span>
      <div className="min-w-0 whitespace-nowrap font-semibold text-[20px] leading-none md:text-[22px]">{children}</div>
    </div>
  )
}

export default function ServerOverviewClient() {
  const { data, error, isLoading } = useServerData()
  const { status, setStatus } = useStatus()
  const { filter, setFilter } = useFilter()
  const t = useTranslations("ServerOverviewClient")
  const disableCartoon = getEnv("NEXT_PUBLIC_DisableCartoon") === "true"

  const seaBlueRingClass =
    "ring-1 ring-white/10 transition-all hover:ring-[#5DADE2] dark:border dark:border-white/10 dark:bg-neutral-900/60 dark:shadow-lg dark:shadow-black/20 dark:ring-white/10 dark:backdrop-blur-md dark:hover:ring-[#5DADE2]"
  const overviewCardContentClass = "flex h-full min-h-[84px] items-center px-7 py-4 md:min-h-[92px]"
  const titleClass = "shrink-0 whitespace-nowrap font-normal text-[17px] leading-none"

  if (error) {
    const errorInfo = error as any
    return (
      <div className="flex flex-col items-center justify-center">
        <p className="font-medium text-sm opacity-40">
          Error status:{errorInfo?.status} {errorInfo.info?.cause ?? errorInfo?.message}
        </p>
        <p className="font-medium text-sm opacity-40">{t("error_message")}</p>
      </div>
    )
  }

  return (
    <>
      <section className="grid grid-cols-1 gap-5 sm:grid-cols-2 lg:grid-cols-12">
        <Card
          onClick={() => {
            setFilter(false)
            setStatus("all")
          }}
          className={cn(seaBlueRingClass, "group cursor-pointer lg:col-span-2", {
            "border-transparent ring-2 ring-[#5DADE2] dark:ring-[#5DADE2]":
              status === "all" && filter === false,
          })}
        >
          <CardContent className={overviewCardContentClass}>
            <section className="flex w-full items-center justify-between gap-3">
              <p className={titleClass}>{t("p_816-881_Totalservers")}</p>
              {data?.result ? (
                <CountBlock dotClass="bg-blue-500"><AnimateCountClient count={data?.result.length} /></CountBlock>
              ) : (
                <Loader visible={true} />
              )}
            </section>
          </CardContent>
        </Card>

        <Card
          onClick={() => {
            setFilter(false)
            setStatus("online")
          }}
          className={cn(seaBlueRingClass, "cursor-pointer lg:col-span-2", {
            "border-transparent ring-2 ring-[#5DADE2] dark:ring-[#5DADE2]": status === "online",
          })}
        >
          <CardContent className={overviewCardContentClass}>
            <section className="flex w-full items-center justify-between gap-3">
              <p className={titleClass}>{t("p_1610-1676_Onlineservers")}</p>
              {data?.result ? (
                <CountBlock dotClass="animate-ping bg-green-500"><AnimateCountClient count={data?.live_servers} /></CountBlock>
              ) : (
                <Loader visible={true} />
              )}
            </section>
          </CardContent>
        </Card>

        <Card
          onClick={() => {
            setFilter(false)
            setStatus("offline")
          }}
          className={cn(seaBlueRingClass, "cursor-pointer lg:col-span-2", {
            "border-transparent ring-2 ring-[#5DADE2] dark:ring-[#5DADE2]": status === "offline",
          })}
        >
          <CardContent className={overviewCardContentClass}>
            <section className="flex w-full items-center justify-between gap-3">
              <p className={titleClass}>{t("p_2532-2599_Offlineservers")}</p>
              {data?.result ? (
                <CountBlock dotClass="animate-ping bg-red-500"><AnimateCountClient count={data?.offline_servers} /></CountBlock>
              ) : (
                <Loader visible={true} />
              )}
            </section>
          </CardContent>
        </Card>

        <Card
          onClick={() => {
            setStatus("all")
            setFilter(true)
          }}
          className={cn(seaBlueRingClass, "group cursor-pointer lg:col-span-3", {
            "border-transparent ring-2 ring-[#5DADE2] dark:ring-[#5DADE2]": filter === true,
          })}
        >
          <CardContent className={cn(overviewCardContentClass, "relative")}>
            <section className="flex w-full items-center justify-between gap-4">
              <p className={titleClass}>{t("p_3463-3530_Totalbandwidth")}</p>
              {data?.result ? (
                <section className="grid min-w-0 grid-cols-2 gap-1.5 text-right font-semibold text-[14px] leading-none">
                  <p className="inline-flex min-w-[76px] items-center justify-center whitespace-nowrap rounded-md bg-blue-500/10 px-2.5 py-2 text-blue-800 tabular-nums shadow-[inset_0_1px_0_rgba(255,255,255,0.08)] dark:bg-blue-500/15 dark:text-blue-400">
                    ↑ {formatBytes(data?.total_out_bandwidth)}
                  </p>
                  <p className="inline-flex min-w-[76px] items-center justify-center whitespace-nowrap rounded-md bg-purple-500/10 px-2.5 py-2 text-purple-800 tabular-nums shadow-[inset_0_1px_0_rgba(255,255,255,0.08)] dark:bg-purple-500/15 dark:text-purple-400">
                    ↓ {formatBytes(data?.total_in_bandwidth)}
                  </p>
                </section>
              ) : (
                <Loader visible={true} />
              )}
            </section>

            {!disableCartoon && (
              <Image
                className="absolute top-[-85px] right-3 z-50 w-20 scale-90 transition-all group-hover:opacity-50 md:scale-100"
                alt={"Hamster1963"}
                src={blogMan}
                priority
              />
            )}
          </CardContent>
        </Card>

        <Card
          onClick={() => {
            setStatus("all")
            setFilter(true)
          }}
          className={cn(seaBlueRingClass, "cursor-pointer sm:col-span-2 lg:col-span-3")}
        >
          <CardContent className="flex h-full min-h-[128px] items-center justify-center px-6 py-4 md:min-h-[138px]">
            {data?.result ? (
              <CombinedSpeedAreaChart uploadSpeed={data?.total_out_speed || 0} downloadSpeed={data?.total_in_speed || 0} />
            ) : (
              <Loader visible={true} />
            )}
          </CardContent>
        </Card>
      </section>

      {data?.result === undefined && !isLoading && (
        <div className="flex flex-col items-center justify-center">
          <p className="font-medium text-sm opacity-40">{t("error_message")}</p>
        </div>
      )}
    </>
  )
}
