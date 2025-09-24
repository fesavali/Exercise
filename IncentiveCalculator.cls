public class IncentiveCalculator {

    public static void calculateIncentives(Id loanId) {
        Loan__c loan = [SELECT Loan_Amount__c, Borrower_Status_New__c, Impact_Points__c, Bonuses__c, Revenue__c, Country_New__c 
                        FROM Loan__c WHERE Id = :loanId];
        List<Loan_Balance__c> balances = [SELECT End_of_Month_Balance__c 
                                          FROM Loan_Balance__c WHERE Loan__c = :loanId];

        Incentive__c incentive = new Incentive__c();
        incentive.Loan__c = loanId;

        incentive.Max_FLC__c = calculateMaxFLC(loan);
        incentive.Max_OI__c = calculateMaxOI(loan);
        incentive.Quarterly_Earnings__c = calculateQuarterlyEarnings(balances);

        upsert incentive;
    }

    public static Decimal calculateMaxOI(Loan__c loan) {
        // Initialize OI variables
        Decimal baseOI = 0;
        Decimal impactFactor = 0;

        // Ensure loan amount threshold is met
        if (loan.Loan_Amount__c == null || loan.Loan_Amount__c < 15000) {
            return 0; // No OI for loans below the threshold
        }

        // Base OI calculation based on revenue
        if (loan.Revenue__c != null && loan.Revenue__c >= 1000000) {
            baseOI = loan.Revenue__c * 0.0015;
        }

        // Impact points adjustment
        if (loan.Impact_Points__c != null) {
            impactFactor = loan.Impact_Points__c * 0.005;
        }

        // Deserialize bonuses safely
        Map<String, Boolean> bonuses = new Map<String, Boolean>();
        if (!String.isBlank(loan.Bonuses__c)) {
            try {
                bonuses = (Map<String, Boolean>) JSON.deserialize(loan.Bonuses__c, Map<String, Boolean>.class);
            } catch (Exception e) {
                System.debug('Failed to deserialize Bonuses__c: ' + e.getMessage());
            }
        }

        // Apply bonuses
        if (getBonusValue(bonuses, 'youth_owned')) {
            baseOI += 1000;
        }
        if (getBonusValue(bonuses, 'climate_smart')) {
            baseOI += 2000;
        }
        if (getBonusValue(bonuses, 'gender_inclusive')) {
            baseOI += 1500;
        }

        // Country-specific adjustments
        if (!String.isBlank(loan.Country_New__c) && 
            (loan.Country_New__c.contains('Kenya') || loan.Country_New__c.contains('Tanzania'))) {
            baseOI *= 1.1; // 10% increase for specific countries
        }

        return baseOI + impactFactor;
    }

    public static Decimal calculateMaxFLC(Loan__c loan) {
        if (loan.Loan_Amount__c == null) {
            return 0; // Default to zero if no loan amount
        }

        // Initialize FLC variables
        Decimal baseFactor = 0.04;
        Decimal factorIncrement = 0;

        if (!String.isBlank(loan.Borrower_Status_New__c) && loan.Borrower_Status_New__c.contains('Returning')) {
            factorIncrement = 0.01;
        }

        Decimal totalFactor = baseFactor + factorIncrement + 
                              (loan.Impact_Points__c != null ? loan.Impact_Points__c * 0.005 : 0);
        return loan.Loan_Amount__c * totalFactor;
    }

    public static Decimal calculateQuarterlyEarnings(List<Loan_Balance__c> balances) {
        if (balances == null || balances.isEmpty()) {
            return 0; // Default to zero if no balances
        }

        Decimal quarterlyEarnings = 0;

        for (Loan_Balance__c balance : balances) {
            Decimal balanceOI = balance.End_of_Month_Balance__c * 0.06;
            Decimal balanceFLC = balance.End_of_Month_Balance__c * 0.055;
            quarterlyEarnings += balanceOI + balanceFLC;
        }

        return quarterlyEarnings;
    }

    public static Boolean getBonusValue(Map<String, Boolean> bonuses, String key) {
        return bonuses != null && bonuses.containsKey(key) && bonuses.get(key);
    }
}
