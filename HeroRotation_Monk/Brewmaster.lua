--- ============================ HEADER ============================
--- ======= LOCALIZE =======
-- Addon
local addonName, addonTable = ...;
-- HeroDBC
local DBC        = HeroDBC.DBC
-- HeroLib
local HL         = HeroLib
local Cache      = HeroCache
local Unit       = HL.Unit
local Player     = Unit.Player
local Target     = Unit.Target
local Pet        = Unit.Pet
local Spell      = HL.Spell
local MultiSpell = HL.MultiSpell
local Item       = HL.Item
-- HeroRotation
local HR         = HeroRotation
local AoEON      = HR.AoEON
local CDsON      = HR.CDsON
-- Lua
local mathmin    = math.min
local pairs      = pairs;


--- ============================ CONTENT ===========================
--- ======= APL LOCALS =======
-- luacheck: max_line_length 9999

-- Spells
local S = Spell.Monk.Brewmaster;
local I = Item.Monk.Brewmaster;

-- Create table to exclude above trinkets from On Use function
local OnUseExcludes = {
  -- BfA
--  I.PocketsizedComputationDevice:ID(),
--  I.AshvanesRazorCoral:ID(),
}

-- Rotation Var
local Enemies5y
local Enemies8y
local EnemiesCount8
local IsInMeleeRange, IsInAoERange
local ShouldReturn; -- Used to get the return string
local Interrupts = {
  { S.SpearHandStrike, "Cast Spear Hand Strike (Interrupt)", function () return true end },
}
local Stuns = {
  { S.LegSweep, "Cast Leg Sweep (Stun)", function () return true end },
}
local Traps = {
  { S.Paralysis, "Cast Paralysis (Stun)", function () return true end },
}

-- GUI Settings
local Everyone = HR.Commons.Everyone;
local Monk = HR.Commons.Monk;
local Settings = {
  General    = HR.GUISettings.General,
  Commons    = HR.GUISettings.APL.Monk.Commons,
  Brewmaster = HR.GUISettings.APL.Monk.Brewmaster
};

-- Legendary variables
local CelestialInfusionEquipped = Player:HasLegendaryEquipped(88)
local CharredPassionsEquipped = Player:HasLegendaryEquipped(86)
local EscapeFromRealityEquipped = Player:HasLegendaryEquipped(82)
local FatalTouchEquipped = Player:HasLegendaryEquipped(85)
local InvokersDelightEquipped = Player:HasLegendaryEquipped(83)
local ShaohaosMightEquipped = Player:HasLegendaryEquipped(89)
local StormstoutsLastKegEquipped = Player:HasLegendaryEquipped(87)
local SwiftsureWrapsEquipped = Player:HasLegendaryEquipped(84)

HL:RegisterForEvent(function()
  VarFoPPreChan = 0
end, "PLAYER_REGEN_ENABLED")

-- Melee Is In Range w/ Movement Handlers
local function IsInMeleeRange(range)
  if S.TigerPalm:TimeSinceLastCast() <= Player:GCD() then
    return true
  end
  return range and Target:IsInMeleeRange(range) or Target:IsInMeleeRange(5)
end

local function UseItems()
  -- use_items
  local TrinketToUse = Player:GetUseableTrinkets(OnUseExcludes)
  if TrinketToUse then
    if HR.Cast(TrinketToUse, nil, Settings.Commons.TrinketDisplayStyle) then return "Generic use_items for " .. TrinketToUse:Name(); end
  end
end

-- Compute healing amount available from orbs
local function HealingSphereAmount()
  return 1.5 * Player:AttackPowerDamageMod() * (1 + (Player:VersatilityDmgPct() / 100)) * S.ExpelHarm:Count()
end

local function GetStaggerTick(ThisSpell)
  local ThisSpellID = ThisSpell:ID()
  for i = 1, 40 do
    local _, _, _, _, _, _, _, _, _, ThisDebuffID, _, _, _, _, _, ThisStaggerTick = UnitDebuff('player', i)
      if (ThisDebuffID == ThisSpellID) then
        return ThisStaggerTick
    end
  end
end

-- I am going keep this function in place in case it is needed in the future.
-- The code is sound for a smoothing of damage intake.
-- However this is not needed in the current APL.
local function ShouldPurify ()
  local NextStaggerTick = 0;
  local NextStaggerTickMaxHPPct = 0;
  local StaggersRatioPct = 0;

  if Player:DebuffUp(S.HeavyStagger) then
    NextStaggerTick = GetStaggerTick(S.HeavyStagger)
--    NextStaggerTick = select(16, Player:DebuffInfo(S.HeavyStagger, true, true))
  elseif Player:DebuffUp(S.ModerateStagger) then
    NextStaggerTick = GetStaggerTick(S.ModerateStagger)
--    NextStaggerTick = select(16, Player:DebuffInfo(S.ModerateStagger, true, true))
  elseif Player:DebuffUp(S.LightStagger) then
    NextStaggerTick = GetStaggerTick(S.LightStagger)
--    NextStaggerTick = select(16, Player:DebuffInfo(S.LightStagger, false, true))
  end

  if NextStaggerTick > 0 then
    NextStaggerTickMaxHPPct = (NextStaggerTick / Player:StaggerMax()) * 100;
    StaggersRatioPct = (Player:Stagger() / Player:StaggerFull()) * 100;
  end

  -- Do not purify at the start of a combat since the normalization is not stable yet
  if HL.CombatTime() <= 9 then return false end;

  -- Do purify only if we are loosing more than 3% HP per second (1.5% * 2 since it ticks every 500ms), i.e. above Grey level
  if NextStaggerTickMaxHPPct > 1.5 and StaggersRatioPct > 0 then
    -- 3% is considered a Moderate Stagger
    if NextStaggerTickMaxHPPct <= 3 then -- Yellow: 6% HP per second, only if the stagger ratio is > 80%
      return Settings.Brewmaster.Purify.Low and StaggersRatioPct > 80 or false;
    -- 4.5% is considered a Heavy Stagger
    elseif NextStaggerTickMaxHPPct <= 4.5 then -- Orange: <= 9% HP per second, only if the stagger ratio is > 71%
      return Settings.Brewmaster.Purify.Medium and StaggersRatioPct > 71 or false;
    elseif NextStaggerTickMaxHPPct <= 9 then -- Red: <= 18% HP per second, only if the stagger ratio value is > 53%
      return Settings.Brewmaster.Purify.High and StaggersRatioPct > 53 or false;
    else -- Magenta: > 18% HP per second, ASAP
      return true;
    end
  end
end

local ShuffleDuration = 5;
local function Defensives()
  local IsTanking = Player:IsTankingAoE(8) or Player:IsTanking(Target);

  -- celestial_brew,if=buff.blackout_combo.down&incoming_damage_1999ms>(health.max*0.1+stagger.last_tick_damage_4)&buff.elusive_brawler.stack<2
  -- Note: Extra handling of the charge management only while tanking.
  --       "- (IsTanking and 1 + (Player:BuffRemains(S.Shuffle) <= ShuffleDuration * 0.5 and 0.5 or 0) or 0)"
  -- TODO: See if this can be optimized
  if S.CelestialBrew:IsCastable() and Settings.Brewmaster.ShowCelestialBrewCD and Player:BuffDown(S.BlackoutComboBuff) and (IsTanking and 1 + (Player:BuffRemains(S.Shuffle) <= ShuffleDuration * 0.5 and 0.5 or 0) or 0) and Player:BuffStack(S.ElusiveBrawlerBuff) < 2 then
    if HR.Cast(S.CelestialBrew, Settings.Brewmaster.GCDasOffGCD.CelestialBrew) then return "Celestial Brew"; end
  end
  -- purifying_brew
  if Settings.Brewmaster.Purify.Enabled and S.PurifyingBrew:IsCastable() then
    if HR.Cast(S.PurifyingBrew, Settings.Brewmaster.OffGCDasOffGCD.PurifyingBrew) then return "Purifying Brew"; end
  end
  -- Blackout Combo Stagger Pause w/ Celestial Brew
  if S.CelestialBrew:IsCastable() and Settings.Brewmaster.ShowCelestialBrewCD and Player:BuffUp(S.BlackoutComboBuff) and Player:HealingAbsorbed() and ShouldPurify() then
    if HR.Cast(S.CelestialBrew, Settings.Brewmaster.GCDasOffGCD.CelestialBrew) then return "Celestial Brew Stagger Pause"; end
  end
  -- Dampen Harm
  if S.DampenHarm:IsCastable() and Settings.Brewmaster.ShowDampenHarmCD then
    if HR.Cast(S.DampenHarm, Settings.Brewmaster.GCDasOffGCD.DampenHarm) then return "Dampen Harm"; end
  end
  -- Fortifying Brew
  if S.FortifyingBrew:IsCastable() then
    if HR.Cast(S.FortifyingBrew, Settings.Brewmaster.GCDasOffGCD.FortifyingBrew) then return "Fortifying Brew"; end
  end
end

--- ======= ACTION LISTS =======
local function APL()
  -- Unit Update
  IsInMeleeRange();
  Enemies5y = Player:GetEnemiesInMeleeRange(5) -- Multiple Abilities
  Enemies8y = Player:GetEnemiesInMeleeRange(8) -- Multiple Abilities
  EnemiesCount8 = #Enemies8y -- AOE Toogle

  --- Out of Combat
  if not Player:AffectingCombat() and Everyone.TargetIsValid() then
    -- flask
    -- food
    -- augmentation
    -- snapshot_stats
    -- potion
    if I.PotionofPhantomFire:IsReady() and Settings.Commons.UsePotions then
      if HR.CastSuggested(I.PotionofPhantomFire) then return "Potion of Phantom Fire"; end
    end
    if I.PotionofSpectralAgility:IsReady() and Settings.Commons.UsePotions then
      if HR.CastSuggested(I.PotionofSpectralAgility) then return "Potion of Spectral Agility"; end
    end
    if I.PotionofDeathlyFixation:IsReady() and Settings.Commons.UsePotions then
      if HR.CastSuggested(I.PotionofDeathlyFixation) then return "Potion of Deathly Fixation"; end
    end
    if I.PotionofEmpoweredExorcisms:IsReady() and Settings.Commons.UsePotions then
      if HR.CastSuggested(I.PotionofEmpoweredExorcisms) then return "Potion of Empowered Exorcisms"; end
    end
    if I.PotionofHardenedShadows:IsReady() and Settings.Commons.UsePotions then
      if HR.CastSuggested(I.PotionofHardenedShadows) then return "Potion of Hardened Shadows"; end
    end
    if I.PotionofSpectralStamina:IsReady() and Settings.Commons.UsePotions then
      if HR.CastSuggested(I.PotionofSpectralStamina) then return "Potion of Spectral Stamina"; end
    end
    -- chi_burst
    if S.ChiBurst:IsCastable() then
      if HR.Cast(S.ChiBurst, nil, nil, not Target:IsInRange(40)) then return "Chi Burst"; end
    end
    -- chi_wave
    if S.ChiWave:IsCastable() then
      if HR.Cast(S.ChiWave, nil, nil, not Target:IsInRange(40)) then return "Chi Wave"; end
    end
  end

  --- In Combat
  if Everyone.TargetIsValid() then
    -- auto_attack
    -- Interrupts
    local ShouldReturn = Everyone.Interrupt(5, S.SpearHandStrike, Settings.Commons.OffGCDasOffGCD.SpearHandStrike, Interrupts); if ShouldReturn then return ShouldReturn; end
    -- Stun
    local ShouldReturn = Everyone.Interrupt(5, S.LegSweep, Settings.Commons.GCDasOffGCD.LegSweep, Stuns); if ShouldReturn and Settings.General.InterruptWithStun then return ShouldReturn; end
    -- Trap
    local ShouldReturn = Everyone.Interrupt(5, S.Paralysis, Settings.Commons.GCDasOffGCD.Paralysis, Stuns); if ShouldReturn and Settings. General.InterruptWithStun then return ShouldReturn; end
    -- Defensives
    ShouldReturn = Defensives(); if ShouldReturn then return ShouldReturn; end
    if HR.CDsON() then
      -- use_item
      if (Settings.Commons.UseTrinkets) then
        if (true) then
          local ShouldReturn = UseItems(); if ShouldReturn then return ShouldReturn; end
        end
      end
      -- potion
      if I.PotionofPhantomFire:IsReady() and Settings.Commons.UsePotions then
        if HR.CastSuggested(I.PotionofPhantomFire) then return "Potion of Phantom Fire 2"; end
      end
      if I.PotionofSpectralAgility:IsReady() and Settings.Commons.UsePotions then
        if HR.CastSuggested(I.PotionofSpectralAgility) then return "Potion of Spectral Agility 2"; end
      end
      if I.PotionofDeathlyFixation:IsReady() and Settings.Commons.UsePotions then
        if HR.CastSuggested(I.PotionofDeathlyFixation) then return "Potion of Deathly Fixation 2"; end
      end
      if I.PotionofEmpoweredExorcisms:IsReady() and Settings.Commons.UsePotions then
        if HR.CastSuggested(I.PotionofEmpoweredExorcisms) then return "Potion of Empowered Exorcisms 2"; end
      end
      if I.PotionofHardenedShadows:IsReady() and Settings.Commons.UsePotions then
        if HR.CastSuggested(I.PotionofHardenedShadows) then return "Potion of Hardened Shadows 2"; end
      end
      if I.PotionofSpectralStamina:IsReady() and Settings.Commons.UsePotions then
        if HR.CastSuggested(I.PotionofSpectralStamina) then return "Potion of Spectral Stamina 2"; end
      end
      -- blood_fury
      if S.BloodFury:IsCastable() then
        if HR.Cast(S.BloodFury, Settings.Commons.OffGCDasOffGCD.Racials) then return "Blood Fury"; end
      end
      -- berserking
      if S.Berserking:IsCastable() then
        if HR.Cast(S.Berserking, Settings.Commons.OffGCDasOffGCD.Racials) then return "Berserking"; end
      end
      -- lights_judgment
      if S.LightsJudgment:IsCastable() then
        if HR.Cast(S.LightsJudgment, Settings.Commons.OffGCDasOffGCD.Racials, not Target:IsInRange(40)) then return "Lights Judgment"; end
      end
      -- fireblood
      if S.Fireblood:IsCastable() then
        if HR.Cast(S.Fireblood, Settings.Commons.OffGCDasOffGCD.Racials) then return "Fireblood"; end
      end
      -- ancestral_call
      if S.AncestralCall:IsCastable() then
        if HR.Cast(S.AncestralCall, Settings.Commons.OffGCDasOffGCD.Racials) then return "Ancestral Call"; end
      end
      -- bag_of_tricks
      if S.BagOfTricks:IsCastable() then
        if HR.Cast(S.BagOfTricks, Settings.Commons.OffGCDasOffGCD.Racials, not Target:IsInRange(40)) then return "Bag of Tricks"; end
      end
      -- weapons_of_order
      if S.WeaponsOfOrder:IsCastable() then
        if HR.Cast(S.WeaponsOfOrder, nil, Settings.Commons.CovenantDisplayStyle) then return "Weapons Of Order cd 1"; end
      end
      -- fallen_order
      if S.FallenOrder:IsCastable() then
        if HR.Cast(S.FallenOrder, nil, Settings.Commons.CovenantDisplayStyle) then return "Fallen Order cd 1"; end
      end
      -- bonedust_brew
      if S.BonedustBrew:IsCastable() then
        if HR.Cast(S.BonedustBrew, nil, Settings.Commons.CovenantDisplayStyle) then return "Bonedust Brew cd 1"; end
      end
      -- invoke_niuzao_the_black_ox
      if S.InvokeNiuzaoTheBlackOx:IsCastable() and HL.BossFilteredFightRemains(">", 25) then
        if HR.Cast(S.InvokeNiuzaoTheBlackOx, Settings.Brewmaster.GCDasOffGCD.InvokeNiuzaoTheBlackOx) then return "Invoke Niuzao the Black Ox"; end
      end
      -- black_ox_brew,if=cooldown.purifying_brew.charges_fractional<0.5
      if S.BlackOxBrew:IsCastable() and S.PurifyingBrew:ChargesFractional() < 0.5 then
        if HR.Cast(S.BlackOxBrew, Settings.Brewmaster.OffGCDasOffGCD.BlackOxBrew) then return "Black Ox Brew"; end
      end
      -- black_ox_brew,if=(energy+(energy.regen*cooldown.keg_smash.remains))<40&buff.blackout_combo.down&cooldown.keg_smash.up
      if S.BlackOxBrew:IsCastable() and (Player:Energy() + (Player:EnergyRegen() * S.KegSmash:CooldownRemains())) < 40 and Player:BuffDown(S.BlackoutComboBuff) and S.KegSmash:CooldownUp() then
        if HR.Cast(S.BlackOxBrew, Settings.Brewmaster.OffGCDasOffGCD.BlackOxBrew) then return "Black Ox Brew 2"; end
      end
    end
    -- keg_smash,if=spell_targets>=2
    if S.KegSmash:IsCastable() and HR.AoEON() and EnemiesCount8 >= 2 then
      if HR.Cast(S.KegSmash, nil, nil, not Target:IsSpellInRange(S.KegSmash)) then return "Keg Smash 1"; end
    end
    -- faeline_stomp,if=spell_targets>=2
    if S.FaelineStomp:IsCastable() and HR.AoEON() and EnemiesCount8 >= 2 then
      if HR.Cast(S.FaelineStomp, nil, Settings.Commons.CovenantDisplayStyle) then return "Faeline Stomp cd 1"; end
    end
    -- keg_smash,if=buff.weapons_of_order.up
    if S.KegSmash:IsCastable() and Player:BuffUp(S.WeaponsOfOrder) then
      if HR.Cast(S.KegSmash, nil, nil, not Target:IsSpellInRange(S.KegSmash)) then return "Keg Smash 2"; end
    end
    -- tiger_palm,if=talent.rushing_jade_wind.enabled&buff.blackout_combo.up&buff.rushing_jade_wind.up
    if S.TigerPalm:IsCastable() and S.RushingJadeWind:IsAvailable() and Player:BuffUp(S.BlackoutComboBuff) and Player:BuffUp(S.RushingJadeWind) then
      if HR.Cast(S.TigerPalm, nil, nil, not Target:IsSpellInRange(S.TigerPalm)) then return "Tiger Palm 1"; end
    end
    -- breath_of_fire,if=buff.charred_passions.down&runeforge.charred_passions.equipped
    if S.BreathOfFire:IsCastable(10, true) and (Player:BuffDown(S.CharredPassions) and CharredPassionsEquipped) then
      if HR.Cast(S.BreathOfFire, nil, nil, not Target:IsInMeleeRange(8)) then return "Breath of Fire 1"; end
    end
    -- blackout_strike
    if S.BlackoutKick:IsCastable() then
      if HR.Cast(S.BlackoutKick, nil, nil, not Target:IsSpellInRange(S.BlackoutKick)) then return "Blackout Kick"; end
    end
    -- keg_smash
    if S.KegSmash:IsCastable() then
      if HR.Cast(S.KegSmash, nil, nil, not Target:IsSpellInRange(S.KegSmash)) then return "Keg Smash 3"; end
    end
    -- faeline_stomp
    if S.FaelineStomp:IsCastable() then
      if HR.Cast(S.FaelineStomp, nil, Settings.Commons.CovenantDisplayStyle) then return "Faeline Stomp cd 2"; end
    end
    -- expel_harm,if=buff.gift_of_the_ox.stack>=3
    -- Note : Extra handling to prevent Expel Harm over-healing
    if S.ExpelHarm:IsReady() and S.ExpelHarm:Count() >= 3 and Player:Health() + HealingSphereAmount() < Player:MaxHealth() then
      if HR.Cast(S.ExpelHarm, nil, nil, not Target:IsInMeleeRange(8)) then return "Expel Harm 2"; end
    end
  if S.TouchOfDeath:IsReady() and Target:HealthPercentage() <= 15 then
    if HR.Cast(S.TouchOfDeath, Settings.Brewmaster.GCDasOffGCD.TouchOfDeath, nil, not Target:IsSpellInRange(S.TouchOfDeath)) then return "Touch Of Death 1"; end
  end
    -- rushing_jade_wind,if=buff.rushing_jade_wind.down
    if S.RushingJadeWind:IsCastable() and Player:BuffDown(S.RushingJadeWind) then
      if HR.Cast(S.RushingJadeWind, nil, nil, not Target:IsInMeleeRange(8)) then return "Rushing Jade Wind"; end
    end
    -- spinning_crane_kick,if=buff.charred_passions.up
    if S.SpinningCraneKick:IsCastable() and Player:BuffUp(S.CharredPassions) then
      if HR.Cast(S.SpinningCraneKick, nil, nil, not Target:IsInMeleeRange(8)) then return "Spinning Crane Kick 1"; end
    end
    -- breath_of_fire,if=buff.blackout_combo.down&(buff.bloodlust.down|(buff.bloodlust.up&dot.breath_of_fire_dot.refreshable))
    if S.BreathOfFire:IsCastable(10, true) and (Player:BuffDown(S.BlackoutComboBuff) and (Player:BloodlustDown() or (Player:BloodlustUp() and Target:BuffRefreshable(S.BreathOfFireDotDebuff)))) then
      if HR.Cast(S.BreathOfFire, nil, nil, not Target:IsInMeleeRange(8)) then return "Breath of Fire 2"; end
    end
    -- chi_burst
    if S.ChiBurst:IsCastable() then
      if HR.Cast(S.ChiBurst, nil, nil, not Target:IsInRange(40)) then return "Chi Burst 2"; end
    end
    -- chi_wave
    if S.ChiWave:IsCastable() then
      if HR.Cast(S.ChiWave, nil, nil, not Target:IsInRange(40)) then return "Chi Wave 2"; end
    end
    -- spinning_crane_kick,if=active_enemies>=3&cooldown.keg_smash.remains>gcd&(energy+(energy.regen*(cooldown.keg_smash.remains+execute_time)))>=65&(!talent.spitfire.enabled|!runeforge.charred_passions.equipped)
    if S.SpinningCraneKick:IsCastable() and (HR.AoEON() and EnemiesCount8 >= 3 and S.KegSmash:CooldownRemains() > Player:GCD() and ((Player:Energy() + (Player:EnergyRegen() * (S.KegSmash:CooldownRemains() + S.SpinningCraneKick:ExecuteTime())) >= 65)) and (not S.Spitfire:IsAvailable() or not CharredPassionsEquipped)) then
      if HR.Cast(S.SpinningCraneKick, nil, nil, not Target:IsInMeleeRange(8)) then return "Spinning Crane Kick 2"; end
    end
    -- tiger_palm,if=!talent.blackout_combo.enabled&cooldown.keg_smash.remains>gcd&(energy+(energy.regen*(cooldown.keg_smash.remains+gcd)))>=65
    if S.TigerPalm:IsCastable() and (not S.BlackoutCombo:IsAvailable() and S.KegSmash:CooldownRemains() > Player:GCD() and ((Player:Energy() + (Player:EnergyRegen() * (S.KegSmash:CooldownRemains() + Player:GCD()))) >= 65)) then
      if HR.Cast(S.TigerPalm, nil, nil, not Target:IsSpellInRange(S.TigerPalm)) then return "Tiger Palm 3"; end
    end
    -- arcane_torrent,if=energy<31
    if S.ArcaneTorrent:IsCastable() and Player:Energy() < 31 then
      if HR.Cast(S.ArcaneTorrent, Settings.Commons.OffGCDasOffGCD.Racials, nil, not Target:IsInMeleeRange(8)) then return "arcane_torrent"; end
    end
    -- rushing_jade_wind
    if S.RushingJadeWind:IsCastable() then
      if HR.Cast(S.RushingJadeWind, nil, nil, not Target:IsInMeleeRange(8)) then return "Rushing Jade Wind 2"; end
    end
    -- Manually added Pool filler
    if HR.Cast(S.PoolEnergy) and not Settings.Brewmaster.NoBrewmasterPooling then return "Pool Energy"; end
  end
end

local function Init()
end

HR.SetAPL(268, APL, Init);

-- Last Update: 2020-12-07

-- # Executed before combat begins. Accepts non-harmful actions only.
-- actions.precombat=flask
-- actions.precombat+=/food
-- actions.precombat+=/augmentation
-- # Snapshot raid buffed stats before combat begins and pre-potting is done.
-- actions.precombat+=/snapshot_stats
-- actions.precombat+=/potion
-- actions.precombat+=/chi_burst
-- actions.precombat+=/chi_wave

-- # Executed every time the actor is available.
-- actions=auto_attack
-- actions+=/spear_hand_strike,if=target.debuff.casting.react
-- actions+=/gift_of_the_ox,if=health<health.max*0.65
-- actions+=/dampen_harm,if=incoming_damage_1500ms&buff.fortifying_brew.down
-- actions+=/fortifying_brew,if=incoming_damage_1500ms&(buff.dampen_harm.down|buff.diffuse_magic.down)
-- actions+=/use_item,name=dreadfire_vessel
-- actions+=/potion
-- actions+=/blood_fury
-- actions+=/berserking
-- actions+=/lights_judgment
-- actions+=/fireblood
-- actions+=/ancestral_call
-- actions+=/bag_of_tricks
-- actions+=/invoke_niuzao_the_black_ox,if=target.time_to_die>25
-- actions+=/touch_of_death,if=target.health.pct<=15
-- actions+=/weapons_of_order
-- actions+=/fallen_order
-- actions+=/bonedust_brew
-- actions+=/purifying_brew
-- # Black Ox Brew is currently used to either replenish brews based on less than half a brew charge available, or low energy to enable Keg Smash
-- actions+=/black_ox_brew,if=cooldown.purifying_brew.charges_fractional<0.5
-- actions+=/black_ox_brew,if=(energy+(energy.regen*cooldown.keg_smash.remains))<40&buff.blackout_combo.down&cooldown.keg_smash.up
-- # Offensively, the APL prioritizes KS on cleave, BoS else, with energy spenders and cds sorted below
-- actions+=/keg_smash,if=spell_targets>=2
-- actions+=/faeline_stomp,if=spell_targets>=2
-- # cast KS at top prio during WoO buff
-- actions+=/keg_smash,if=buff.weapons_of_order.up
-- # Celestial Brew priority whenever it took significant damage (adjust the health.max coefficient according to intensity of damage taken), and to dump excess charges before BoB.
-- actions+=/celestial_brew,if=buff.blackout_combo.down&incoming_damage_1999ms>(health.max*0.1+stagger.last_tick_damage_4)&buff.elusive_brawler.stack<2
-- actions+=/tiger_palm,if=talent.rushing_jade_wind.enabled&buff.blackout_combo.up&buff.rushing_jade_wind.up
-- actions+=/breath_of_fire,if=buff.charred_passions.down&runeforge.charred_passions.equipped
-- actions+=/blackout_kick
-- actions+=/keg_smash
-- actions+=/faeline_stomp
-- actions+=/expel_harm,if=buff.gift_of_the_ox.stack>=3
-- actions+=/touch_of_death
-- actions+=/rushing_jade_wind,if=buff.rushing_jade_wind.down
-- actions+=/spinning_crane_kick,if=buff.charred_passions.up
-- actions+=/breath_of_fire,if=buff.blackout_combo.down&(buff.bloodlust.down|(buff.bloodlust.up&dot.breath_of_fire_dot.refreshable))
-- actions+=/chi_burst
-- actions+=/chi_wave
-- actions+=/spinning_crane_kick,if=active_enemies>=3&cooldown.keg_smash.remains>gcd&(energy+(energy.regen*(cooldown.keg_smash.remains+execute_time)))>=65&(!talent.spitfire.enabled|!runeforge.charred_passions.equipped)
-- actions+=/tiger_palm,if=!talent.blackout_combo.enabled&cooldown.keg_smash.remains>gcd&(energy+(energy.regen*(cooldown.keg_smash.remains+gcd)))>=65
-- actions+=/arcane_torrent,if=energy<31
-- actions+=/rushing_jade_wind
