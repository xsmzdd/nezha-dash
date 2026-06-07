import { ArrowDownIcon, ArrowUpIcon, BoltIcon, SignalIcon } from "@heroicons/react/20/solid"
import { memo, useId } from "react"
import Link from "next/link"
import { useTranslations } from "next-intl"
import CountryFlagBackdrop from "@/components/CountryFlagBackdrop"
import ServerFlag from "@/components/ServerFlag"
import { Badge } from "@/components/ui/badge"
import { Card } from "@/components/ui/card"
import type { NezhaAPISafe } from "@/lib/drivers/types"
import getEnv from "@/lib/env-entry"
import { GetFontLogoClass, GetOsName, MageMicrosoftWindows } from "@/lib/logo-class"
import { cn, formatBytes, formatNezhaInfo } from "@/lib/utils"

const clampPercent = (value: number) => Math.min(100, Math.max(0, Number.isFinite(value) ? value : 0))

const getUsageColor = (value: number) => {
  const percent = clampPercent(value)

  if (percent <= 25) return "#22C55E" // 绿
  if (percent <= 50) return "#FACC15" // 黄
  if (percent <= 75) return "#FB923C" // 橙
  return "#EF4444" // 红
}

const formatUptime = (seconds: number) => {
  const day = Math.floor(seconds / 86400)
  const hour = Math.floor((seconds % 86400) / 3600)
  const minute = Math.floor((seconds % 3600) / 60)

  if (day > 0) return `${day} d ${hour} h`
  if (hour > 0) return `${hour} h ${minute} min`
  return `${minute} min`
}

function MetricSparkline({ value, color }: { value: number; color: string }) {
  const percent = clampPercent(value)
  const gradientId = useId().replace(/:/g, "")
  const lineId = `metric-line-${gradientId}`
  const areaId = `metric-area-${gradientId}`
  const points = Array.from({ length: 15 }, (_, index) => {
    const wave = Math.sin((index + 1) * 0.9 + percent / 16) * 9
    const drift = Math.cos((index + 2) * 0.55 + percent / 25) * 5
    const y = Math.min(34, Math.max(8, 24 - wave - drift + (50 - percent) / 18))
    return `${index * 5},${y.toFixed(1)}`
  }).join(" ")
  const areaPoints = `0,36 ${points} 70,36`

  return (
    <svg
      className="mt-1 h-8 w-[76px] overflow-visible opacity-80"
      viewBox="0 0 70 38"
      aria-hidden="true"
    >
      <defs>
        <linearGradient id={lineId} x1="0" x2="1" y1="0" y2="0">
          <stop offset="0%" stopColor={color} stopOpacity="0.35" />
          <stop offset="100%" stopColor={color} />
        </linearGradient>
        <linearGradient id={areaId} x1="0" x2="0" y1="0" y2="1">
          <stop offset="0%" stopColor={color} stopOpacity="0.36" />
          <stop offset="100%" stopColor={color} stopOpacity="0" />
        </linearGradient>
      </defs>
      <polygon points={areaPoints} fill={`url(#${areaId})`} />
      <polyline
        points={points}
        fill="none"
        stroke={`url(#${lineId})`}
        strokeLinecap="round"
        strokeLinejoin="round"
        strokeWidth="2.4"
      />
    </svg>
  )
}

function ResourceDottedRing({ label, value, detail, color }: { label: string; value: number; detail: string; color: string }) {
  const percent = clampPercent(value)
  const dotCount = 56
  const activeDots = Math.round((percent / 100) * dotCount)
  const dots = Array.from({ length: dotCount }, (_, index) => {
    const angle = (-90 + (360 / dotCount) * index) * (Math.PI / 180)
    const radius = 36
    return {
      x: 41 + Math.cos(angle) * radius,
      y: 41 + Math.sin(angle) * radius,
      active: index < activeDots,
    }
  })

  return (
    <div className="relative flex size-[82px] items-center justify-center">
      <svg className="absolute inset-0 size-full" viewBox="0 0 82 82" aria-hidden="true">
        {dots.map((dot, index) => (
          <circle
            // biome-ignore lint/suspicious/noArrayIndexKey: stable decorative ring dots
            key={index}
            cx={dot.x}
            cy={dot.y}
            r={1.85}
            fill={dot.active ? color : "rgba(255,255,255,0.18)"}
            opacity={dot.active ? 0.95 : 0.52}
          />
        ))}
      </svg>
      <div className="relative z-10 flex size-[58px] flex-col items-center justify-center rounded-full bg-white/[0.055] text-center shadow-[inset_0_0_18px_rgba(255,255,255,0.04)]">
        <span className="font-bold text-[20px] leading-none tracking-tight tabular-nums drop-shadow-[0_1px_3px_rgba(0,0,0,0.45)]">
          {Math.round(percent)}%
        </span>
        <span className="mt-1 max-w-[46px] truncate font-bold text-[8px] uppercase tracking-[0.08em] opacity-55">{label}</span>
        <span className="mt-0.5 max-w-[50px] truncate font-mono text-[8px] leading-none opacity-45">{detail}</span>
      </div>
    </div>
  )
}

function ResourceRing({ label, value, detail }: { label: string; value: number; detail: string }) {
  const percent = clampPercent(value)
  const color = getUsageColor(percent)
  const gradient = `linear-gradient(90deg, ${color}55 0%, ${color} 100%)`

  return (
    <div className="min-w-0">
      <div className="flex min-h-[128px] flex-col items-center justify-start gap-1.5 rounded-[14px] px-1.5 py-2 dark:hidden">
        <div className="flex w-full flex-col items-center gap-0.5 text-center leading-tight">
          <span className="font-bold text-[12px] text-foreground/70">{label}</span>
          <span className="font-mono font-bold text-[10px] text-foreground/45 tabular-nums break-all">{detail}</span>
        </div>
        <div className="relative h-2.5 w-full overflow-hidden rounded-full bg-black/10">
          <span
            className="absolute inset-y-0 left-0 rounded-full shadow-[0_0_14px_rgba(21,60,70,0.18)]"
            style={{ width: `${percent}%`, background: gradient }}
          />
        </div>
        <div
          className="font-bold text-[17px] leading-none tabular-nums"
          style={{ color }}
        >
          {Math.round(percent)}%
        </div>
        <MetricSparkline value={percent} color={color} />
      </div>

      <div className="hidden flex-col items-center gap-1 dark:flex">
        <ResourceDottedRing label={label} value={percent} detail={detail} color={color} />
        <MetricSparkline value={percent} color={color} />
        <div className="text-center">
          <p className="font-bold text-[13px] opacity-85">{label}</p>
          <p className="mt-0.5 text-[12px] opacity-60">{detail}</p>
        </div>
      </div>
    </div>
  )
}

function MiniBars({ value, variant }: { value: number; variant: "latency" | "loss" }) {
  const barCount = 26
  const activeBars = variant === "loss" ? Math.round((100 - clampPercent(value)) / 100 * barCount) : barCount

  return (
    <div className="flex h-8 items-end gap-1 rounded-xl bg-black/5 px-2 py-1.5 dark:bg-black/25">
      {Array.from({ length: barCount }).map((_, index) => (
        <span
          // biome-ignore lint/suspicious/noArrayIndexKey: purely decorative bars
          key={index}
          className={cn(
            "w-1 flex-1 rounded-full",
            index < activeBars
              ? variant === "latency"
                ? "bg-amber-400"
                : "bg-emerald-400"
              : "bg-white/10",
          )}
        />
      ))}
    </div>
  )
}

function getOptionalMonitorValue(serverInfo: NezhaAPISafe, keys: string[]) {
  const source = serverInfo as any
  for (const key of keys) {
    const value = source?.[key] ?? source?.status?.[key]
    if (typeof value === "number" && Number.isFinite(value)) return value
  }
  return undefined
}

function ServerCardPro({ serverInfo }: { serverInfo: NezhaAPISafe }) {
  const t = useTranslations("ServerCard")
  const { id, name, country_code, online, cpu, mem, stg, host, uptime, disk_total } =
    formatNezhaInfo(serverInfo)

  const showFlag = getEnv("NEXT_PUBLIC_ShowFlag") === "true"
  const showNetTransfer = getEnv("NEXT_PUBLIC_ShowNetTransfer") === "true"
  const diskUsed = serverInfo.status.DiskUsed || 0
  const memoryUsed = serverInfo.status.MemUsed || 0
  const systemName = host.Platform.includes("Windows") ? "Windows" : GetOsName(host.Platform)
  const latency = getOptionalMonitorValue(serverInfo, ["avg_delay", "AvgDelay", "delay", "Delay", "latency", "Latency"])
  const packetLoss = getOptionalMonitorValue(serverInfo, ["packet_loss", "PacketLoss", "loss", "Loss"])
  const hasMonitorStats = latency !== undefined || packetLoss !== undefined

  const saveSession = () => {
    sessionStorage.setItem("fromMainPage", "true")
  }

  return (
    <Link onClick={saveSession} href={`/server/${id}`} prefetch={false}>
      <Card
        className={cn(
          "server-glass-card group relative min-h-[356px] cursor-pointer overflow-hidden rounded-[22px] border border-white/45 bg-white/20 p-0 text-foreground shadow-[0_10px_32px_rgba(0,0,0,0.08)] backdrop-blur-md transition-all hover:-translate-y-0.5 hover:border-blue-400/40 hover:shadow-[0_14px_42px_rgba(37,99,235,0.16)]",
          "dark:text-white",
          !online && "opacity-80 grayscale-[0.25]",
        )}
      >
        {showFlag ? <CountryFlagBackdrop country_code={country_code} direction="vertical" /> : null}
        <div className="pointer-events-none absolute inset-0 z-[1] bg-gradient-to-br from-white/24 via-transparent to-blue-500/8 dark:from-white/8" />
        <div className="relative z-10 flex h-full flex-col">
          <header className="flex items-start justify-between gap-4 border-white/35 border-b dark:border-white/10 px-4 py-3">
            <section className="flex min-w-0 flex-1 items-start gap-3">
              <div className="mt-1 flex h-7 w-7 shrink-0 items-center justify-center overflow-hidden rounded-md bg-white/45 dark:bg-white/10">
                {showFlag ? <ServerFlag country_code={country_code} /> : null}
              </div>
              <div className="min-w-0 flex-1">
                <h3 className="truncate font-bold text-[17px] leading-tight">{name}</h3>
                <div className="mt-1.5 flex flex-wrap items-center gap-2 text-foreground/55 dark:text-white/45 text-[12px]">
                  <span className="inline-flex max-w-full items-center gap-1 rounded-md bg-white/45 dark:bg-white/7 px-2 py-1">
                    {host.Platform.includes("Windows") ? (
                      <MageMicrosoftWindows className="size-3 shrink-0" />
                    ) : (
                      <span className={`fl-${GetFontLogoClass(host.Platform)} shrink-0`} />
                    )}
                    <span className="truncate">{systemName}</span>
                  </span>
                  <span>·</span>
                  <span>{formatUptime(uptime)}</span>
                </div>
              </div>
            </section>
            <Badge
              variant="secondary"
              className={cn(
                "inline-flex h-7 min-w-[48px] shrink-0 items-center justify-center whitespace-nowrap rounded-full border-0 px-3 py-1 text-center font-bold text-[12px] leading-none",
                online ? "bg-emerald-500 text-black" : "bg-red-500 text-white",
              )}
            >
              {online ? t("Online") : t("Offline")}
            </Badge>
          </header>

          {online ? (
            <div className="flex flex-1 flex-col gap-4 px-4 py-4">
              <section className="grid grid-cols-3 gap-4">
                <ResourceRing label={t("CPU")} value={cpu} detail={`${cpu.toFixed(1)}%`} />
                <ResourceRing label={t("Mem")} value={mem} detail={formatBytes(memoryUsed)} />
                <ResourceRing label={t("STG")} value={stg} detail={formatBytes(diskUsed || disk_total)} />
              </section>

              <section className="rounded-2xl bg-white/35 dark:bg-white/[0.055] p-4 shadow-[inset_0_1px_0_rgba(255,255,255,0.06)]">
                <div className="mb-3 flex min-w-0 flex-col gap-2 text-foreground/70 dark:text-white/70">
                  <span className="flex items-center gap-1.5 whitespace-nowrap font-bold text-[13px] leading-none">
                    <SignalIcon className="size-4 shrink-0" />
                    <span className="whitespace-nowrap">{t("NetSpeed")}</span>
                  </span>
                  <div className="grid min-w-0 grid-cols-2 gap-3 font-mono text-[12px] leading-none sm:text-[13px]">
                    <span className="flex min-w-0 items-center justify-center gap-1 rounded-md bg-emerald-500/10 px-2.5 py-2.5 text-emerald-300">
                      <span className="shrink-0">↑</span>
                      <span className="min-w-0 whitespace-nowrap text-center tabular-nums">{formatBytes(serverInfo.status.NetOutSpeed)}/s</span>
                    </span>
                    <span className="flex min-w-0 items-center justify-center gap-1 rounded-md bg-blue-500/10 px-2.5 py-2.5 text-blue-300">
                      <span className="shrink-0">↓</span>
                      <span className="min-w-0 whitespace-nowrap text-center tabular-nums">{formatBytes(serverInfo.status.NetInSpeed)}/s</span>
                    </span>
                  </div>
                </div>

                {showNetTransfer && (
                  <div className="grid gap-2 border-white/35 border-t dark:border-white/10 pt-3 text-[13px]">
                    <div className="flex flex-col gap-1 text-foreground/60 dark:text-white/60 sm:flex-row sm:items-center sm:justify-between">
                      <span>{t("Traffic")}</span>
                      <span className="font-mono text-foreground/70 text-[12px] dark:text-white/70">
                        ↑ {formatBytes(serverInfo.status.NetOutTransfer)}　↓ {formatBytes(serverInfo.status.NetInTransfer)}
                      </span>
                    </div>
                  </div>
                )}

                {hasMonitorStats && (
                  <div className="mt-4 grid grid-cols-2 gap-3">
                    {latency !== undefined && (
                      <div>
                        <div className="mb-1 flex items-center justify-between font-mono text-[12px] text-foreground/60 dark:text-white/60">
                          <span>{t("Latency")}</span>
                          <span>{latency.toFixed(0)} ms</span>
                        </div>
                        <MiniBars value={latency} variant="latency" />
                      </div>
                    )}
                    {packetLoss !== undefined && (
                      <div>
                        <div className="mb-1 flex items-center justify-between font-mono text-[12px] text-foreground/60 dark:text-white/60">
                          <span>{t("Loss")}</span>
                          <span>{packetLoss.toFixed(1)}%</span>
                        </div>
                        <MiniBars value={packetLoss} variant="loss" />
                      </div>
                    )}
                  </div>
                )}
              </section>
            </div>
          ) : (
            <div className="flex flex-1 flex-col items-center justify-center gap-4 p-8 text-center">
              <BoltIcon className="size-12 text-red-400" />
              <div>
                <p className="font-bold text-xl">{t("Offline")}</p>
                <p className="mt-2 text-sm text-foreground/55 dark:text-white/45">{name}</p>
              </div>
              <div className="flex gap-3 font-mono text-sm text-foreground/55 dark:text-white/55">
                <span className="inline-flex items-center gap-1">
                  <ArrowUpIcon className="size-4" /> 0 B/s
                </span>
                <span className="inline-flex items-center gap-1">
                  <ArrowDownIcon className="size-4" /> 0 B/s
                </span>
              </div>
            </div>
          )}
        </div>
      </Card>
    </Link>
  )
}

export default memo(ServerCardPro)
