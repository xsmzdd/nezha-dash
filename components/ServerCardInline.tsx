import Link from "next/link"
import { useTranslations } from "next-intl"
import CountryFlagBackdrop from "@/components/CountryFlagBackdrop"
import ServerFlag from "@/components/ServerFlag"
import ServerUsageBar from "@/components/ServerUsageBar"
import { Card } from "@/components/ui/card"
import type { NezhaAPISafe } from "@/lib/drivers/types"
import getEnv from "@/lib/env-entry"
import { GetFontLogoClass, GetOsName, MageMicrosoftWindows } from "@/lib/logo-class"
import { cn, formatBytes, formatNezhaInfo } from "@/lib/utils"

import { Separator } from "./ui/separator"

export default function ServerCardInline({ serverInfo }: { serverInfo: NezhaAPISafe }) {
  const t = useTranslations("ServerCard")
  const { id, name, country_code, online, cpu, up, down, mem, stg, host } =
    formatNezhaInfo(serverInfo)

  const showFlag = getEnv("NEXT_PUBLIC_ShowFlag") === "true"

  const saveSession = () => {
    sessionStorage.setItem("fromMainPage", "true")
  }

  return online ? (
    <Link onClick={saveSession} href={`/server/${id}`} prefetch={true}>
      <Card
        className={cn(
          "server-glass-card relative flex w-full min-w-[1180px] cursor-pointer items-center justify-start gap-5 overflow-hidden p-4 transition-all hover:shadow-sm hover:ring-stone-300 md:px-6 lg:flex-row dark:hover:ring-stone-700",
        )}
      >
        {showFlag ? <CountryFlagBackdrop country_code={country_code} direction="horizontal" /> : null}
        <section
          className={cn("relative z-10 grid items-center gap-2 lg:w-48")}
          style={{ gridTemplateColumns: "auto auto 1fr" }}
        >
          <span className="h-2 w-2 shrink-0 self-center rounded-full bg-green-500" />
          <div
            className={cn(
              "flex items-center justify-center",
              showFlag ? "min-w-[17px]" : "min-w-0",
            )}
          >
            {showFlag ? <ServerFlag country_code={country_code} /> : null}
          </div>
          <div className="relative w-40">
            <p
              className={cn(
                "break-normal font-bold tracking-tight",
                showFlag ? "text-[13px]" : "text-[13px]",
              )}
            >
              {name}
            </p>
          </div>
        </section>
        <Separator orientation="vertical" className="relative z-10 mx-1 ml-3 h-10" />
        <div className="relative z-10 flex flex-col gap-2">
          <section className={cn("grid flex-1 grid-cols-9 items-center gap-6")}>
            <div className={"flex flex-row items-center gap-2 whitespace-nowrap"}>
              <div className="font-semibold text-[16px]">
                {host.Platform.includes("Windows") ? (
                  <MageMicrosoftWindows className="size-2.5" />
                ) : (
                  <p className={`fl-${GetFontLogoClass(host.Platform)}`} />
                )}
              </div>
              <div className={"flex w-28 flex-col"}>
                <p className="text-muted-foreground text-[13px]">{t("System")}</p>
                <div className="flex items-center font-semibold text-[15px]">
                  {host.Platform.includes("Windows") ? "Windows" : GetOsName(host.Platform)}
                </div>
              </div>
            </div>
            <div className={"flex w-28 flex-col"}>
              <p className="text-muted-foreground text-[13px]">{t("Uptime")}</p>
              <div className="flex items-center font-semibold text-[15px]">
                {(serverInfo?.status.Uptime / 86400).toFixed(0)} {"Days"}
              </div>
            </div>
            <div className={"flex w-28 flex-col"}>
              <p className="text-muted-foreground text-[13px]">{t("CPU")}</p>
              <div className="flex items-center font-semibold text-[15px]">{cpu.toFixed(2)}%</div>
              <ServerUsageBar value={cpu} />
            </div>
            <div className={"flex w-28 flex-col"}>
              <p className="text-muted-foreground text-[13px]">{t("Mem")}</p>
              <div className="flex items-center font-semibold text-[15px]">{mem.toFixed(2)}%</div>
              <ServerUsageBar value={mem} />
            </div>
            <div className={"flex w-28 flex-col"}>
              <p className="text-muted-foreground text-[13px]">{t("STG")}</p>
              <div className="flex items-center font-semibold text-[15px]">{stg.toFixed(2)}%</div>
              <ServerUsageBar value={stg} />
            </div>
            <div className={"flex w-24 flex-col"}>
              <p className="text-muted-foreground text-[13px]">{t("Upload")}</p>
              <div className="flex items-center font-semibold text-[15px]">
                {up >= 1024 ? `${(up / 1024).toFixed(2)}G/s` : `${up.toFixed(2)}M/s`}
              </div>
            </div>
            <div className={"flex w-24 flex-col"}>
              <p className="text-muted-foreground text-[13px]">{t("Download")}</p>
              <div className="flex items-center font-semibold text-[15px]">
                {down >= 1024 ? `${(down / 1024).toFixed(2)}G/s` : `${down.toFixed(2)}M/s`}
              </div>
            </div>
            <div className={"flex w-28 flex-col"}>
              <p className="text-muted-foreground text-[13px]">{t("TotalUpload")}</p>
              <div className="flex items-center font-semibold text-[15px]">
                {formatBytes(serverInfo.status.NetOutTransfer)}
              </div>
            </div>
            <div className={"flex w-28 flex-col"}>
              <p className="text-muted-foreground text-[13px]">{t("TotalDownload")}</p>
              <div className="flex items-center font-semibold text-[15px]">
                {formatBytes(serverInfo.status.NetInTransfer)}
              </div>
            </div>
          </section>
        </div>
      </Card>
    </Link>
  ) : (
    <Link onClick={saveSession} href={`/server/${id}`} prefetch={true}>
      <Card
        className={cn(
          "server-glass-card relative flex min-h-[76px] min-w-[1180px] flex-row items-center justify-start gap-5 overflow-hidden p-4 transition-all hover:shadow-sm hover:ring-stone-300 md:px-6 lg:flex-row dark:hover:ring-stone-700",
        )}
      >
        {showFlag ? <CountryFlagBackdrop country_code={country_code} direction="horizontal" /> : null}
        <section
          className={cn("relative z-10 grid items-center gap-2 lg:w-52")}
          style={{ gridTemplateColumns: "auto auto 1fr" }}
        >
          <span className="h-2 w-2 shrink-0 self-center rounded-full bg-red-500" />
          <div
            className={cn(
              "flex items-center justify-center",
              showFlag ? "min-w-[17px]" : "min-w-0",
            )}
          >
            {showFlag ? <ServerFlag country_code={country_code} /> : null}
          </div>
          <div className="relative w-40">
            <p
              className={cn(
                "break-normal font-bold tracking-tight",
                showFlag ? "text-[15px]" : "text-[15px]",
              )}
            >
              {name}
            </p>
          </div>
        </section>
      </Card>
    </Link>
  )
}
