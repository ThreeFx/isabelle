(*  Title:      HOL/Auth/Public
    ID:         $Id$
    Author:     Lawrence C Paulson, Cambridge University Computer Laboratory
    Copyright   1996  University of Cambridge

Theory of Public Keys (common to all symmetric-key protocols)

Server keys; initial states of agents; new nonces and keys; function "sees" 
*)

Public = Message + List + 

consts
  pubK    :: agent => key

syntax
  priK    :: agent => key

translations  (*BEWARE! expressions like  (inj priK)  will NOT work!*)
  "priK x"  == "invKey(pubK x)"

consts  (*Initial states of agents -- parameter of the construction*)
  initState :: [agent set, agent] => msg set

primrec initState agent
        (*Agents know their private key and all public keys*)
  initState_Server  "initState lost Server     =    
 		         insert (Key (priK Server)) (Key `` range pubK)"
  initState_Friend  "initState lost (Friend i) =    
 		         insert (Key (priK (Friend i))) (Key `` range pubK)"
  initState_Spy     "initState lost Spy        =    
 		         (Key``invKey``pubK``lost) Un (Key `` range pubK)"


datatype  (*Messages, and components of agent stores*)
  event = Says agent agent msg

consts  
  sees1 :: [agent, event] => msg set

primrec sees1 event
           (*Spy reads all traffic whether addressed to him or not*)
  sees1_Says  "sees1 A (Says A' B X)  = (if A:{B,Spy} then {X} else {})"

consts  
  sees :: [agent set, agent, event list] => msg set

primrec sees list
  sees_Nil  "sees lost A []       = initState lost A"
  sees_Cons "sees lost A (ev#evs) = sees1 A ev Un sees lost A evs"


constdefs
  (*Set of items that might be visible to somebody: complement of the set
        of fresh items*)
  used :: event list => msg set
    "used evs == parts (UN lost B. sees lost B evs)"


rules
  (*Public keys are disjoint, and never clash with private keys*)
  inj_pubK        "inj pubK"
  priK_neq_pubK   "priK A ~= pubK B"

end
