%warning('off', 'Octave:possible-matlab-short-circuit-operator');
clearvars -except seqL;

global E_MIN; global E_MAX; 
E_MIN=[0;0]; %Minimum energy to be stored (lower bound)
E_MAX=[5;4]; %Maximum energy to be stored (upper bound)

%Input: initial state, horizon
%Initial stored energy (user-defined)
%Must be between MIN_STATE and MAX_STATE
E1_INIT=E_MAX(1); 
E2_INIT=E_MAX(2);
%Recurse for 3 iterations (1,2,3)
LAST_ITER=10;
%NO discount factor (not inf horizon)
global DISCOUNT;
DISCOUNT=1;

%NOTE: at end, uOpt will have best control policy, and NetCost will contain total cost of DP operation
%ASSUMING FINAL COST = 0


%Model setup
global MAX_CHARGE; global MAX_DISCHARGE;
MAX_CHARGE=[0;100]; %Maximum charging of the supercapacitor
MAX_DISCHARGE=[5;4]; %Maximum discharging of the 1) battery and 2) supercap

global MIN_LOAD;
MIN_LOAD=0; %Minimum load expected
MAX_LOAD=MAX_DISCHARGE(1)+MAX_DISCHARGE(2);
%SET PROBABILITY DISTRIBUTION for loads... Normal  %<------------------------------- **********
MU_LOAD=floor(0.5*(MAX_LOAD+MIN_LOAD));
%Set stdev so less than 1e-4 probability of outside bounds
SIGMA_LOAD=MAX_LOAD-MIN_LOAD;
while ( (normpdf(MAX_LOAD+1,MU_LOAD,SIGMA_LOAD)>1e-4 || normpdf(MIN_LOAD-1,MU_LOAD,SIGMA_LOAD)>1e-4) && SIGMA_LOAD>1)
    SIGMA_LOAD=SIGMA_LOAD-1;
end
%If probabilities not summing to within 1e-3 of 1, give error
probs=normpdf(linspace(MIN_LOAD,MAX_LOAD,MAX_LOAD-MIN_LOAD+1),MU_LOAD,SIGMA_LOAD);
if sum(probs)<0.999
   disp('Continuous approximation error!!'); 
end
MAX_NUM_ZEROS=3; %Maximum number of zero load counts before end sim

global ALPHA_C; global ALPHA_D; global BETA; global K;
ALPHA_C=[1;1]; %Efficiency of charging
ALPHA_D=[1;1]; %Efficiency of discharging
BETA=[1;1];    %Storage efficiency
K=2;           %Weighting factor for D1^2 cost
PERFECT_EFF=1;

%DP Setup... with duplication for each control input
global V; global D1Opt_State; global D2Opt_State; global expCostE;
V=[]; D1Opt_State=[]; D2Opt_State=[]; expCostE=[];
%COST MATRIX....V(:,k) holds the cost of the kth iteration for each possible state
V(1:(E_MAX(1)-E_MIN(1)+1),1:(E_MAX(2)-E_MIN(2)+1),1:(MAX_LOAD-MIN_LOAD+1),1:LAST_ITER) = Inf;       %1 matrix b/c 1 cost function
%uOptState holds the optimal control U for each state, and for all iterations
D1Opt_State(1:(E_MAX(1)-E_MIN(1)+1),1:(E_MAX(2)-E_MIN(2)+1),1:(MAX_LOAD-MIN_LOAD+1),1:LAST_ITER)=0; 
D2Opt_State(1:(E_MAX(1)-E_MIN(1)+1),1:(E_MAX(2)-E_MIN(2)+1),1:(MAX_LOAD-MIN_LOAD+1),1:LAST_ITER)=0;
%final cost is 0, for all possible states and values of "load"
V(:,:,:,LAST_ITER)=0;

%optNextE will hold optimal NEXT state at state E with load L (at iteration t)... FOR REFERENCE
global optNextE1; global optNextE2;
optNextE1=[]; optNextE2=[];
optNextE1(1:(E_MAX(1)-E_MIN(1)+1),1:(E_MAX(2)-E_MIN(2)+1),1:(MAX_LOAD-MIN_LOAD+1),1:LAST_ITER)=Inf;
optNextE2(1:(E_MAX(1)-E_MIN(1)+1),1:(E_MAX(2)-E_MIN(2)+1),1:(MAX_LOAD-MIN_LOAD+1),1:LAST_ITER)=Inf;

%expCostX will be EXPECTED TOTAL for a given state (cost-to-go AND control cost)
%By default, initialize last iteration costs to 0s
expCostE(:,:,LAST_ITER)=V(:,:,1,LAST_ITER);


for t=(LAST_ITER-1):-1:1                %Start at 2nd-last iteration (time, t), and continue backwards
  %For each state at an iteration...
  for E_Ind1=1:(E_MAX(1)-E_MIN(1)+1)
    for E_Ind2=1:(E_MAX(2)-E_MIN(2)+1)
      %Since expected cost found from adding to running cost, set to 0s initially
      expCostE(E_Ind1,E_Ind2,t)=0;
      %Reset count of admissible loads
      numAdmissibleLoads=0;
    
      %Find cost-to-go for each possible value of perturbation (w)
      %NOTE: this is the perturbation of the current time, leading to an expected cost-to-go for the PREV time
      for indL=1:(MAX_LOAD-MIN_LOAD+1)
        %Map index to value of load
        L=indL+MIN_LOAD-1;
        %CostX_W will be LOWEST cost of next state, for GIVEN perturbation w. (Assume infinite cost by default)        
        expCostE_L(E_Ind1,E_Ind2,indL)=Inf;
        
        %For each possible control for that state (at a given iteration and value of w)...
        %Get CONTROLS and optimal COST of next state (Cost-to-go) for all combos of w and u
        expCostE_L(E_Ind1,E_Ind2,indL)=GetCtrlsUnkNextState( E_Ind1,E_Ind2,indL,t );

        %NOTE: IF NO PERTURBATION.... CostX_W should just hold cost of next state for the given value of u.
        if(expCostE_L(E_Ind1,E_Ind2,indL)==Inf) %If cannot go to any next state FOR GIVEN PERTURBATION w...
          %fprintf('No next state for given L. L=%d, E1=%d, E2=%d\n',L,E_MIN(1)+(E_Ind1-1),E_MIN(2)+(E_Ind2-1));
          %IGNORE possibility of such a perturbation. Perturbation w too large. No admissible next state
        else
          %Else if load admissible, increment count of admissible loads
          numAdmissibleLoads=numAdmissibleLoads+1;
        end
      end
      
      %If the no-load case permits a next state (i.e. not going outside bounds for all controls)...
      if(numAdmissibleLoads~=0)
        P_PERTURB=1/(numAdmissibleLoads); %Set load distribution to be uniform, by default
        
        %Try to calculate expected cost of the state, now knowing the admissible loads
        for indL=1:(MAX_LOAD-MIN_LOAD+1)
          if(expCostE_L(E_Ind1,E_Ind2,indL)~=Inf) %If CAN go to any next state FOR GIVEN PERTURBATION w...
            %Find expected cost of state, to be the Expected Cost for over all random demands at NEXT TIME STAGE t+1
            %1) Determine probability of given load value
                %Map index to value of load
                L=indL+MIN_LOAD-1;
            %P_PERTURB=normpdf(L,MU_LOAD,SIGMA_LOAD);
            %2) Find expectation by adding to running cost, for each value of load...
            expCostE(E_Ind1,E_Ind2,t) = expCostE(E_Ind1,E_Ind2,t) + V(E_Ind1,E_Ind2,indL,t)*P_PERTURB;
          end
        end
      %Else, if zero-load, zero-control state leads to an expected state out of bounds...
      else
        disp("NO POSSIBLE NEXT STATE FOR CURRENT STATE, for all loads.");
        expCostE(E_Ind1,E_Ind2,t)=Inf; %Ignore this state at previous time step when finding the optimal expected next state
      end
      %At end, expCostX contains the expected cost in state (E1,E2)
      
    end
  end
end
%Replace infinite costs with -1%
V(V==inf)=-1;
%Final costs, depending on load
NetCost=V(E1_INIT-E_MIN(1)+1,E2_INIT-E_MIN(2)+1,:,1);


%%TESTING: evaluate policy for a random sequence of loads
%Set up matrices
optE1(1)=E1_INIT; optE2(1)=E2_INIT;
%Find total initial storage (for creating sample load sequences)
TOT_INIT_E=optE1(1)+optE2(1);
% Count errors, for DEBUGGING
countOOB=0;         %Out of bounds count
countRepeatZeros=0; %Count of repeated zero loads
while t<=(LAST_ITER-1)
    %Set state index
    indE1=optE1(t)-E_MIN(1)+1;
    indE2=optE2(t)-E_MIN(2)+1;
    %Create random demand in IID Uniform probability sequence
    MAX_LOAD_STATE=optE1(t)+optE2(t)-1; %Maximum possible load limited to total energy stored in that state
    randL=randi(MAX_LOAD_STATE-MIN_LOAD+1)+MIN_LOAD-1;
    %Or, use sample sequence of pseudo-random demands
    %Select between sequences
    %L=randL;
    seqL=ones(LAST_ITER);
    L=seqL(t);
    %If leads to next state guaranteed out of bounds, decrease load
    while(optNextE1(indE1,indE2,L-MIN_LOAD+1,t)==inf || optNextE2(indE1,indE2,L-MIN_LOAD+1,t)==inf)
        L=L-1;
        countOOB=countOOB+1;
    end
    if(L==0 && countOOB~=0)
        countRepeatZeros=countRepeatZeros+1;
    end
    indL=L-MIN_LOAD+1;
    Load(t)=L;          %Hold value of load (for reference)
    %Get optimal costs for this sequence of loads
    optV(t)=V(indE1,indE2,indL,t);
    %Get costs of other possible states for this state and load??
    %(For comparison)

    %Get optimal policy for this sequence of loads
    D1Opt(t)=D1Opt_State(indE1,indE2,indL,t);
    D2Opt(t)=D2Opt_State(indE1,indE2,indL,t);
    %Get optimal next state, starting at E_INIT
    optE1(t+1)=optNextE1(indE1,indE2,indL,t);
    optE2(t+1)=optNextE2(indE1,indE2,indL,t);
    %Note: cross-check with optNextStateLtd?
    
    %If counted zero loads too many times, break loop
    if(countRepeatZeros==MAX_NUM_ZEROS)
        D1Opt(t+1)=0; D2Opt(t+1)=0;
        optE1(t+1)=optE1(t); optE2(t+1)=optE2(t);
        optV(t+1)=V(optE1(t+1)-E_MIN(1)+1,optE2(t+1)-E_MIN(2)+1,indL,t);
        Load(t+1)=0;
        t=LAST_ITER;
    end
    t=t+1;
end