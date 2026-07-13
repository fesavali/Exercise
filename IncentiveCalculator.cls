public class IncentiveCalculator {

    public class LenderConfig {
        public Boolean eligibleForOI = true;
        public Boolean eligibleForFLC = true;
        public Boolean canRegisterSMEs = true;
        public Decimal minLoanForOI = 15000;
        public Decimal revenueRate = 0.0015;
        public Decimal impactUplift = 0.005;
        public Decimal flcBaseRate = 0.04;
        public Decimal flcReturningIncrement = 0.01;
        public Map<String, Decimal> countryMultipliers =
            new Map<String, Decimal>{'Kenya' => 1.1, 'Tanzania' => 1.1};
        public Map<String, Decimal> valueChainMultipliers = new Map<String, Decimal>();
    }

    // Single source of truth for exception lookup - used at registration AND quarter-end
    public static LenderConfig getLenderConfig(Id lenderId) {
        LenderConfig cfg = new LenderConfig();
        if (lenderId == null) return cfg;

        Lender__c lender = [SELECT Lender_Code__c FROM Lender__c WHERE Id = :lenderId LIMIT 1];
        if (lender == null || String.isBlank(lender.Lender_Code__c)) return cfg;

        List<Lender_Exception__mdt> exceptions = [
            SELECT Eligible_For_OI__c, Eligible_For_FLC__c, Can_Register_SMEs__c,
                   Min_Loan_For_OI__c, Revenue_Rate__c, Impact_Uplift_Per_Point__c,
                   FLC_Base_Rate__c, FLC_Returning_Increment__c,
                   Country_Multiplier_JSON__c, Value_Chain_Multiplier_JSON__c
            FROM Lender_Exception__mdt
            WHERE Lender_Code__c = :lender.Lender_Code__c
            LIMIT 1
        ];

        if (!exceptions.isEmpty()) {
            Lender_Exception__mdt exc = exceptions[0];
            cfg.eligibleForOI = exc.Eligible_For_OI__c;
            cfg.eligibleForFLC = exc.Eligible_For_FLC__c;
            cfg.canRegisterSMEs = exc.Can_Register_SMEs__c;
            if (exc.Min_Loan_For_OI__c != null) cfg.minLoanForOI = exc.Min_Loan_For_OI__c;
            if (exc.Revenue_Rate__c != null) cfg.revenueRate = exc.Revenue_Rate__c;
            if (exc.Impact_Uplift_Per_Point__c != null) cfg.impactUplift = exc.Impact_Uplift_Per_Point__c;
            if (exc.FLC_Base_Rate__c != null) cfg.flcBaseRate = exc.FLC_Base_Rate__c;
            if (exc.FLC_Returning_Increment__c != null) cfg.flcReturningIncrement = exc.FLC_Returning_Increment__c;
            if (!String.isBlank(exc.Country_Multiplier_JSON__c)) {
                cfg.countryMultipliers = (Map<String, Decimal>) JSON.deserialize(
                    exc.Country_Multiplier_JSON__c, Map<String, Decimal>.class);
            }
            if (!String.isBlank(exc.Value_Chain_Multiplier_JSON__c)) {
                cfg.valueChainMultipliers = (Map<String, Decimal>) JSON.deserialize(
                    exc.Value_Chain_Multiplier_JSON__c, Map<String, Decimal>.class);
            }
        }
        return cfg;
    }

    public static void calculateIncentives(Id loanId) {
        Loan__c loan = [SELECT Loan_Amount__c, Borrower_Status_New__c, Impact_Points__c, Bonuses__c,
                                Revenue__c, Country_New__c, Value_Chain__c, Lender__c
                         FROM Loan__c WHERE Id = :loanId];

        List<Loan_Balance__c> balances = [SELECT End_of_Month_Balance__c, Month__c
                                          FROM Loan_Balance__c WHERE Loan__c = :loanId];

        LenderConfig cfg = getLenderConfig(loan.Lender__c);

        Incentive__c incentive = new Incentive__c(Loan__c = loanId);
        List<Incentive__c> existing = [SELECT Id FROM Incentive__c WHERE Loan__c = :loanId LIMIT 1];
        if (!existing.isEmpty()) {
            incentive.Id = existing[0].Id;
        }

        incentive.Max_FLC__c = cfg.eligibleForFLC ? calculateMaxFLC(loan, cfg) : 0;
        incentive.Max_OI__c = cfg.eligibleForOI ? calculateMaxOI(loan, cfg) : 0;
        incentive.Quarterly_Earnings__c = calculateQuarterlyEarnings(balances, cfg);
        upsert incentive;
    }

    public static Decimal calculateMaxOI(Loan__c loan, LenderConfig cfg) {
        Decimal baseOI = 0;
        Decimal impactFactor = 0;

        if (loan.Loan_Amount__c == null || loan.Loan_Amount__c < cfg.minLoanForOI) {
            return 0;
        }
        if (loan.Revenue__c != null && loan.Revenue__c >= 1000000) {
            baseOI = loan.Revenue__c * cfg.revenueRate;
        }
        if (loan.Impact_Points__c != null) {
            impactFactor = loan.Impact_Points__c * cfg.impactUplift;
        }

        Map<String, Boolean> bonuses = new Map<String, Boolean>();
        if (!String.isBlank(loan.Bonuses__c)) {
            try {
                bonuses = (Map<String, Boolean>) JSON.deserialize(loan.Bonuses__c, Map<String, Boolean>.class);
            } catch (Exception e) {
                System.debug('Failed to deserialize Bonuses__c: ' + e.getMessage());
            }
        }
        if (getBonusValue(bonuses, 'youth_owned')) baseOI += 1000;
        if (getBonusValue(bonuses, 'climate_smart')) baseOI += 2000;
        if (getBonusValue(bonuses, 'gender_inclusive')) baseOI += 1500;

        if (!String.isBlank(loan.Country_New__c) && cfg.countryMultipliers.containsKey(loan.Country_New__c)) {
            baseOI *= cfg.countryMultipliers.get(loan.Country_New__c);
        }
        if (!String.isBlank(loan.Value_Chain__c) && cfg.valueChainMultipliers.containsKey(loan.Value_Chain__c)) {
            baseOI *= cfg.valueChainMultipliers.get(loan.Value_Chain__c);
        }

        return baseOI + impactFactor;
    }

    public static Decimal calculateMaxFLC(Loan__c loan, LenderConfig cfg) {
        if (loan.Loan_Amount__c == null) return 0;

        Decimal factorIncrement = 0;
        if (!String.isBlank(loan.Borrower_Status_New__c) && loan.Borrower_Status_New__c == 'Returning') {
            factorIncrement = cfg.flcReturningIncrement;
        }
        Decimal totalFactor = cfg.flcBaseRate + factorIncrement +
                              (loan.Impact_Points__c != null ? loan.Impact_Points__c * cfg.impactUplift : 0);
        return loan.Loan_Amount__c * totalFactor;
    }

    // Sums balances for the CURRENT quarter only (Month__c based), not all-time history
    public static Decimal calculateQuarterlyEarnings(List<Loan_Balance__c> balances, LenderConfig cfg) {
        if (balances == null || balances.isEmpty()) return 0;

        Date today = Date.today();
        Integer currentQuarter = (today.month() - 1) / 3 + 1;

        Decimal quarterlyEarnings = 0;
        for (Loan_Balance__c balance : balances) {
            if (balance.Month__c != null) {
                Integer balanceQuarter = (balance.Month__c.month() - 1) / 3 + 1;
                if (balanceQuarter != currentQuarter || balance.Month__c.year() != today.year()) {
                    continue; // skip balances outside the current quarter
                }
            }
            Decimal balanceOI = cfg.eligibleForOI ? balance.End_of_Month_Balance__c * 0.06 : 0;
            Decimal balanceFLC = cfg.eligibleForFLC ? balance.End_of_Month_Balance__c * 0.055 : 0;
            quarterlyEarnings += balanceOI + balanceFLC;
        }
        return quarterlyEarnings;
    }

    public static Boolean getBonusValue(Map<String, Boolean> bonuses, String key) {
        return bonuses != null && bonuses.containsKey(key) && bonuses.get(key);
    }
}